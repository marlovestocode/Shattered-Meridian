--!strict
-- Covers Server/Combat/HitboxEngine/HitboxEngine.lua -- the engine core, against real Instances.
--
-- Unlike the other two specs in this folder this one needs a Workspace: the whole point of the module
-- is that it queries live bodies at live poses, and a synthetic stand-in for that would test nothing
-- worth testing. The dummies below are the smallest thing the engine accepts (a Model, an anchored
-- root part, a Humanoid) -- which is itself an assertion, since the engine is supposed to work for a
-- bot or a dummy exactly as it does for a player.
--
-- Time is driven through Step(deltaTime, now) rather than by waiting. Nothing here sleeps, and the
-- tunnelling case at the bottom reproduces a frame rate that would be impractical to produce for real.
-- The clock base comes from os.clock() because RequestAttack stamps the swing with it.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)

type HitReport = HitboxTypes.HitReport

local FRAME = 1 / 60

type Dummy = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Id: number,
}

local spawned: { Model } = {}

-- Anchored on purpose: these bodies must stay exactly where a case puts them, and a falling dummy
-- would make every positional assertion here a race against gravity.
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

local function makeDefinition(overrides: { [string]: any }): HitboxTypes.AttackDefinition
	local base: { [string]: any } = {
		DebugName = "SpecSwing",
		Shape = "Box",
		BaseDimensions = { Width = 4, Height = 6, Length = 6 },
		Scaling = { ComboStageMultipliers = { 1 }, MaxScaleMultiplier = 8 },
		-- Four studs in front of the attacker (-Z is forward), so the volume sits ahead of the body
		-- rather than swallowing it.
		Offset = CFrame.new(0, 0, -4),
		AttachmentPart = "Root",
		WindupSeconds = 0,
		ActiveSeconds = 5,
		RecoverySeconds = 0,
		LocksMovement = false,
	}
	for key, value in overrides do
		base[key] = value
	end
	-- Sanitised here rather than inside the engine's cache so each case gets its own definition table
	-- and the weak-keyed cache can never serve one case's attack to another.
	return (HitboxTypes.SanitizeDefinition(base))
end

-- Collects every report the engine emits for the duration of a case.
local function captureHits(): ({ HitReport }, () -> ())
	local hits: { HitReport } = {}
	local disconnect = HitboxEngine.OnHit(function(report: HitReport)
		table.insert(hits, report)
	end)
	return hits, disconnect
end

return function()
	afterEach(function()
		HitboxEngine.Reset()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("HitboxEngine -- registration", function()
		it("registers anything with a model, a root and a humanoid", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			expect(attacker.Id).to.be.ok()
			expect(HitboxEngine.RegisteredCount()).to.equal(1)
			expect(HitboxEngine.GetCombatantId(attacker.Model)).to.equal(attacker.Id)
		end)

		it("returns the same id when the same model registers twice", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local again = HitboxEngine.RegisterCombatant(attacker.Model, attacker.Root, attacker.Humanoid)
			expect(again).to.equal(attacker.Id)
			expect(HitboxEngine.RegisteredCount()).to.equal(1)
		end)

		it("tags the model so other systems can positively identify a fighter", function()
			local CollectionService = game:GetService("CollectionService")
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			expect(CollectionService:HasTag(attacker.Model, HitboxEngineConstants.CombatantTag)).to.equal(true)

			HitboxEngine.UnregisterCombatant(attacker.Id)
			expect(CollectionService:HasTag(attacker.Model, HitboxEngineConstants.CombatantTag)).to.equal(false)
			expect(HitboxEngine.GetCombatantId(attacker.Model)).to.equal(nil)
		end)
	end)

	describe("HitboxEngine.RequestAttack", function()
		it("refuses an unregistered combatant without erroring", function()
			local accepted, reason = HitboxEngine.RequestAttack(9999, makeDefinition({}), 1, 0)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("NotRegistered")
		end)

		it("refuses a second attack while one is in flight", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			expect(HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)).to.equal(true)

			local accepted, reason = HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("Busy")
		end)

		it("puts the combatant into the engaged set", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			expect(HitboxEngine.EngagedCount()).to.equal(1)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Active")
		end)
	end)

	describe("HitboxEngine -- hit detection", function()
		it("reports a hit on an overlapping target", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -4))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 2, 0)
			local base = os.clock()
			HitboxEngine.Step(FRAME, base + 0.01)
			disconnect()

			expect(#hits).to.equal(1)
			expect(hits[1].Attacker).to.equal(attacker.Model)
			expect(hits[1].Target).to.equal(target.Model)
			expect(hits[1].TargetPart).to.equal(target.Root)
			expect(hits[1].ComboStage).to.equal(2)
			expect(hits[1].Shape).to.equal("Box")
		end)

		it("does not report a target out of range", function()
			makeDummy("Target", Vector3.new(0, 5, -40))
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(0)
		end)

		it("does not report a target BEHIND the attacker, since the volume is offset forward", function()
			makeDummy("Target", Vector3.new(0, 5, 4))
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(0)
		end)

		it("never reports the attacker hitting itself", function()
			-- The volume is centred on the attacker's own root, so every sample gathers their own body.
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ Offset = CFrame.identity }), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(0)
		end)

		it("reports a target only once however many samples it stays inside for", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -4))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			local base = os.clock()
			for step = 1, 10 do
				HitboxEngine.Step(FRAME, base + 0.01 + FRAME * step)
			end
			disconnect()

			expect(#hits).to.equal(1)
		end)

		it("honours MaxTargetsPerSwing", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("TargetA", Vector3.new(-2, 5, -4))
			makeDummy("TargetB", Vector3.new(2, 5, -4))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ BaseDimensions = { Width = 12, Height = 6, Length = 6 }, MaxTargetsPerSwing = 1 }),
				1,
				0
			)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(1)
		end)

		it("stops reporting once the Active window has closed", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ ActiveSeconds = 0.05 }), 1, 0)
			local base = os.clock()
			-- Well past the window, so the swing is finished before the target ever appears.
			HitboxEngine.Step(FRAME, base + 0.5)
			makeDummy("Target", Vector3.new(0, 5, -4))
			HitboxEngine.Step(FRAME, base + 0.6)
			disconnect()

			expect(#hits).to.equal(0)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
		end)
	end)

	describe("HitboxEngine -- dynamic sizing", function()
		local function scalingDefinition(): HitboxTypes.AttackDefinition
			return makeDefinition({
				BaseDimensions = { Width = 2, Height = 4, Length = 2 },
				Offset = CFrame.identity,
				Scaling = { ComboStageMultipliers = { 1, 2, 4 }, MaxScaleMultiplier = 8 },
			})
		end

		it("reports the LIVE post-scaling dimensions, not the authored ones", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -3))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, scalingDefinition(), 3, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(1)
			-- Combo stage 3 is the x4 multiplier, so a 2-stud box is live at 8.
			expect(hits[1].Dimensions.Length).to.equal(8)
			expect(hits[1].Dimensions.Width).to.equal(8)
		end)

		it("reaches further at a higher combo stage -- the same attack misses at stage 1", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -3))
			local hits, disconnect = captureHits()

			-- Stage 1: a 2-stud box reaches 1 stud forward plus the narrow-phase margin. The target's
			-- centre is 3 studs away.
			HitboxEngine.RequestAttack(attacker.Id, scalingDefinition(), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			expect(#hits).to.equal(0)

			HitboxEngine.CancelAttack(attacker.Id, "SpecReset")

			-- Stage 3: the same attack, four times the volume, now reaches.
			HitboxEngine.RequestAttack(attacker.Id, scalingDefinition(), 3, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(1)
		end)

		it("scales with power level as well as combo stage", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -3))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({
					BaseDimensions = { Width = 2, Height = 4, Length = 2 },
					Offset = CFrame.identity,
					Scaling = {
						ComboStageMultipliers = { 1 },
						PowerMultiplierPerUnit = 1,
						MaxScaleMultiplier = 8,
					},
				}),
				1,
				3
			)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			-- 1 + (1 * 3) = 4x, so a 2-stud box is live at 8.
			expect(#hits).to.equal(1)
			expect(hits[1].Dimensions.Length).to.equal(8)
		end)

		it("clamps at MaxScaleMultiplier so an unbounded power level cannot produce an absurd volume", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -3))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({
					BaseDimensions = { Width = 2, Height = 4, Length = 2 },
					Offset = CFrame.identity,
					Scaling = {
						ComboStageMultipliers = { 1 },
						PowerMultiplierPerUnit = 1,
						MaxScaleMultiplier = 3,
					},
				}),
				1,
				1000
			)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(1)
			expect(hits[1].Dimensions.Length).to.equal(6)
		end)
	end)

	describe("HitboxEngine -- the movement lock", function()
		local LOCK = HitboxEngineConstants.RootControlLockedAttribute

		it("sets the Attribute for a locking swing and clears it when the swing ends", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ LocksMovement = true, ActiveSeconds = 0.1, RecoverySeconds = 0.05 }),
				1,
				0
			)
			local base = os.clock()

			HitboxEngine.Step(FRAME, base + 0.01)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)

			HitboxEngine.Step(FRAME, base + 0.5)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)
		end)

		it("holds the lock through recovery, so a heavy attack cannot be cancelled by moving", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ LocksMovement = true, ActiveSeconds = 0.05, RecoverySeconds = 1 }),
				1,
				0
			)
			local base = os.clock()

			HitboxEngine.Step(FRAME, base + 0.2)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Recovery")
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)
		end)

		it("never sets the Attribute for a non-locking swing", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ LocksMovement = false }), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)
		end)

		it("releases the lock when the swing is cancelled mid-Active", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ LocksMovement = true }), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)

			HitboxEngine.CancelAttack(attacker.Id, "Parried")
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
		end)

		it("releases the lock when the combatant is unregistered mid-swing", function()
			-- A character despawning must not leave RootControlLocked set: on a respawn that reuses the
			-- Humanoid, that would park the new character's parkour permanently.
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ LocksMovement = true }), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)

			HitboxEngine.UnregisterCombatant(attacker.Id)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)
		end)
	end)

	describe("HitboxEngine -- continuity under load", function()
		it("catches a target a single end-of-frame sample would have tunnelled straight past", function()
			-- THE case this engine exists for. The attacker teleports 40 studs sideways across one long
			-- frame, passing over a target standing at the origin. Neither the pose at the start of that
			-- frame nor the pose at the end is anywhere near the target, so a hitbox sampled once per
			-- Heartbeat reports nothing at all and the swing visibly passes through them.
			--
			-- The arithmetic, which is what makes this a real assertion rather than a hopeful one:
			-- 40 studs across MaxSubstepsPerFrame (8) substeps puts sampled poses at x = -17, -12, -7,
			-- -2, 3, 8, 13, 18. The nearest two straddle the target without either containing it -- a
			-- 2-stud-wide box plus a 0.5-stud margin covers [-3.5,-0.5] and [1.5,4.5], and the target
			-- sits at 0. So substepping ALONE is not enough here either; it is SweptContainsPoint,
			-- interpolating within that final 5-stud substep, that finds the contact.
			local attacker = makeDummy("Attacker", Vector3.new(-22, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, 0))
			local hits, disconnect = captureHits()

			local definition = makeDefinition({
				BaseDimensions = { Width = 2, Height = 6, Length = 2 },
				Offset = CFrame.identity,
			})

			HitboxEngine.RequestAttack(attacker.Id, definition, 1, 0)
			local base = os.clock()

			-- Frame one establishes the previous-sample pose out at x = -22.
			HitboxEngine.Step(FRAME, base + 0.01)
			expect(#hits).to.equal(0)

			-- Neither end of the coming frame contains the target. Asserted directly against the
			-- geometry so this case cannot silently degrade into "the endpoints happened to overlap."
			local margin = HitboxEngineConstants.NarrowPhaseMarginStuds
			local dimensions = definition.BaseDimensions
			local startPose = CFrame.new(-22, 5, 0)
			local endPose = CFrame.new(18, 5, 0)
			local point = Vector3.new(0, 5, 0)
			expect(HitboxGeometry.ContainsPoint("Box", dimensions, startPose:PointToObjectSpace(point), margin)).to.equal(
				false
			)
			expect(HitboxGeometry.ContainsPoint("Box", dimensions, endPose:PointToObjectSpace(point), margin)).to.equal(
				false
			)

			attacker.Root.CFrame = endPose
			HitboxEngine.Step(0.25, base + 0.3)
			disconnect()

			expect(#hits).to.equal(1)
		end)

		it("clamps an absurd frame time instead of fast-forwarding a whole attack", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ ActiveSeconds = 5 }), 1, 0)
			-- A resumed Studio session can deliver a frame of minutes. The swing must still be running.
			HitboxEngine.Step(600, os.clock() + 0.05)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Active")
		end)
	end)

	describe("HitboxEngine -- lifecycle housekeeping", function()
		it("retires a combatant whose character has been destroyed", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			expect(HitboxEngine.RegisteredCount()).to.equal(1)

			attacker.Model.Parent = nil
			HitboxEngine.Step(FRAME, os.clock())
			expect(HitboxEngine.RegisteredCount()).to.equal(0)
		end)

		it("leaves the engaged set empty once a swing completes", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ ActiveSeconds = 0.05 }), 1, 0)
			expect(HitboxEngine.EngagedCount()).to.equal(1)

			HitboxEngine.Step(FRAME, os.clock() + 0.5)
			expect(HitboxEngine.EngagedCount()).to.equal(0)
		end)

		it("stops delivering to a disconnected OnHit subscriber", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -4))
			local hits, disconnect = captureHits()
			disconnect()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)

			expect(#hits).to.equal(0)
		end)

		it("keeps sampling for other subscribers when one of them errors", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -4))

			local disconnectBad = HitboxEngine.OnHit(function()
				error("consumer blew up")
			end)
			local hits, disconnectGood = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnectBad()
			disconnectGood()

			expect(#hits).to.equal(1)
		end)
	end)
end
