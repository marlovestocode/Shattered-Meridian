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
local NetworkLatency = require(ServerScriptService.Server.Combat.NetworkLatency)

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

-- Parents a Tool onto a dummy's Model the same way Humanoid:EquipTool does for a real player -- a
-- direct child of the character -- so resolveAttachmentPart's "Weapon" case (model:
-- FindFirstChildOfClass("Tool")) finds it. Handle and Blade are both real, independently placed and
-- sized BaseParts: Handle at the dummy's own position (where a naive "just use the grip" resolution
-- would anchor), Blade wherever the case wants the swing to actually reach, so a test can prove which
-- one the engine picked from where a hit does or doesn't land rather than reaching into a private
-- function.
local function equipWeapon(
	dummy: Dummy,
	options: { HandlePosition: Vector3?, BladePosition: Vector3?, BladeSize: Vector3? }
): Tool
	local tool = Instance.new("Tool")
	tool.Name = "TestSword"

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Anchored = true
	handle.CanCollide = false
	handle.CFrame = CFrame.new(options.HandlePosition or dummy.Root.Position)
	handle.Parent = tool

	local blade = Instance.new("Part")
	blade.Name = "Blade"
	blade.Anchored = true
	blade.CanCollide = false
	blade.Size = options.BladeSize or Vector3.new(2, 2, 2)
	blade.CFrame = CFrame.new(options.BladePosition or dummy.Root.Position)
	blade.Parent = tool

	-- Not added to `spawned` -- it is a descendant of dummy.Model, which afterEach already destroys, so
	-- tracking it separately would just double-destroy an already-gone Instance.
	tool.Parent = dummy.Model
	return tool
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
		NetworkLatency.SetResolver(nil)
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

	describe("HitboxEngine -- a Volumeless swing", function()
		it("hits nothing in front of the attacker, where an ordinary swing of the same shape would", function()
			makeDummy("Target", Vector3.new(0, 5, -4))
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local hits, disconnect = captureHits()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ Volumeless = true }), 1, 0)
			local base = os.clock()
			HitboxEngine.Step(FRAME, base + 0.01)
			HitboxEngine.Step(FRAME, base + 0.1)
			disconnect()
			expect(#hits).to.equal(0)

			HitboxEngine.Reset()
			local again = makeDummy("Attacker2", Vector3.new(0, 5, 0))
			makeDummy("Target2", Vector3.new(0, 5, -4))
			local controlHits, disconnectControl = captureHits()
			HitboxEngine.RequestAttack(again.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnectControl()
			expect(#controlHits).to.equal(1)
		end)

		it("still runs the whole swing: it is accepted, active, and ends", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local accepted = HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ Volumeless = true, ActiveSeconds = 0.1, RecoverySeconds = 0.05 }),
				1,
				0
			)
			expect(accepted).to.equal(true)
			local base = os.clock()
			HitboxEngine.Step(FRAME, base + 0.01)
			expect(HitboxEngine.EngagedCount()).to.equal(1)
			HitboxEngine.Step(FRAME, base + 0.5)
			expect(HitboxEngine.EngagedCount()).to.equal(0)
		end)

		it("keeps the movement lock a locking cast asks for, and releases it when the swing ends", function()
			local LOCK = HitboxEngineConstants.RootControlLockedAttribute
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ Volumeless = true, LocksMovement = true, ActiveSeconds = 0.1, RecoverySeconds = 0.05 }),
				1,
				0
			)
			local base = os.clock()
			HitboxEngine.Step(FRAME, base + 0.01)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)
			HitboxEngine.Step(FRAME, base + 0.5)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)
		end)

		it("survives the sanitiser: absent is false, and a stray value is false", function()
			expect(HitboxTypes.SanitizeDefinition({ Shape = "Box" }).Volumeless).to.equal(false)
			expect(HitboxTypes.SanitizeDefinition({ Shape = "Box", Volumeless = "yes" }).Volumeless).to.equal(false)
			expect(HitboxTypes.SanitizeDefinition({ Shape = "Box", Volumeless = true }).Volumeless).to.equal(true)
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

		it("holds the body, not just the parkour hand-over: SwingRooted rides the lock both ways", function()
			-- RootControlLocked parks parkour and the camera; it never zeroed anyone's speed. SwingRooted is what
			-- RunSystem pins WalkSpeed to 0 off, so a move's "Locks movement" actually stops the attacker.
			local ROOTED = HitboxEngineConstants.SwingRootedAttribute
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			expect(attacker.Humanoid:GetAttribute(ROOTED)).to.equal(nil)

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ LocksMovement = true, ActiveSeconds = 0.1, RecoverySeconds = 0.05 }),
				1,
				0
			)
			local base = os.clock()
			HitboxEngine.Step(FRAME, base + 0.01)
			expect(attacker.Humanoid:GetAttribute(ROOTED)).to.equal(true)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)

			HitboxEngine.Step(FRAME, base + 0.5)
			expect(attacker.Humanoid:GetAttribute(ROOTED)).to.equal(nil)
		end)

		it("never roots a body for a non-locking swing", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ LocksMovement = false }), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			expect(attacker.Humanoid:GetAttribute(HitboxEngineConstants.SwingRootedAttribute)).to.equal(nil)
		end)

		it("locks the WINDUP: held from the swing's first instant, released as the Active window opens", function()
			local ROOTED = HitboxEngineConstants.SwingRootedAttribute
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ LocksWindup = true, WindupSeconds = 0.3, ActiveSeconds = 0.2, RecoverySeconds = 0.5 }),
				1,
				0
			)
			local base = os.clock()
			-- Before the engine has even stepped: the body is already held.
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)
			expect(attacker.Humanoid:GetAttribute(ROOTED)).to.equal(true)

			HitboxEngine.Step(FRAME, base + 0.1)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Windup")
			expect(attacker.Humanoid:GetAttribute(ROOTED)).to.equal(true)

			-- Active opens: a windup-only lock lets go.
			HitboxEngine.Step(FRAME, base + 0.35)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Active")
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)
			expect(attacker.Humanoid:GetAttribute(ROOTED)).to.equal(nil)
		end)

		it(
			"carries one unbroken lock through the whole swing when it locks the windup AND the active window",
			function()
				local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
				HitboxEngine.RequestAttack(
					attacker.Id,
					makeDefinition({
						LocksWindup = true,
						LocksMovement = true,
						WindupSeconds = 0.3,
						ActiveSeconds = 0.2,
						RecoverySeconds = 0.5,
					}),
					1,
					0
				)
				local base = os.clock()
				expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)
				HitboxEngine.Step(FRAME, base + 0.35)
				expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Active")
				expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)
				HitboxEngine.Step(FRAME, base + 0.7)
				expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Recovery")
				expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)
				HitboxEngine.Step(FRAME, base + 1.5)
				expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)
			end
		)

		it("releases a windup lock when the swing is cut in the windup", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ LocksWindup = true, WindupSeconds = 0.5, ActiveSeconds = 0.2 }),
				1,
				0
			)
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(true)
			HitboxEngine.CancelAttack(attacker.Id, "Parried")
			expect(attacker.Humanoid:GetAttribute(LOCK)).to.equal(nil)
		end)

		it("never holds the body in a windup that does not ask for it", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ WindupSeconds = 0.3 }), 1, 0)
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

	describe("HitboxTypes.SourceOf", function()
		it("stamps a swing's contact as Melee", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -4))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(1)
			expect(hits[1].Source).to.equal("Melee")
			expect(HitboxTypes.SourceOf(hits[1])).to.equal("Melee")
		end)

		it("infers a source for a report built without one", function()
			local bare = {} :: any
			expect(HitboxTypes.SourceOf(bare)).to.equal("Melee")
			expect(HitboxTypes.SourceOf({ Projectile = {} } :: any)).to.equal("Projectile")
			expect(HitboxTypes.SourceOf({ Projectile = { DomainId = 3 } } :: any)).to.equal("Realm")
			expect(HitboxTypes.IsShot({ Projectile = { DomainId = 3 } } :: any)).to.equal(true)
			expect(HitboxTypes.IsShot({ Source = "Impact" } :: any)).to.equal(false)
		end)

		it("prefers the stamped source over the shape", function()
			expect(HitboxTypes.SourceOf({ Source = "Impact", Projectile = {} } :: any)).to.equal("Impact")
		end)
	end)

	describe("HitboxEngine -- death", function()
		it("reports no contact on a dead body", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -4))
			target.Humanoid.Health = 0
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(0)
		end)

		it("ends the swing of an attacker killed mid-swing, with nothing more landing", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local hits, disconnect = captureHits()
			local base = os.clock()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, base + FRAME)
			expect(HitboxEngine.GetAttackState(attacker.Id)).never.to.equal("Idle")

			attacker.Humanoid.Health = 0
			-- A body walks into the still-open volume after the death: it must not be struck.
			makeDummy("Late", Vector3.new(0, 5, -4))
			HitboxEngine.Step(FRAME, base + 2 * FRAME)
			disconnect()

			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
			expect(HitboxEngine.EngagedCount()).to.equal(0)
			expect(#hits).to.equal(0)
		end)

		it("refuses a swing from a dead body", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			attacker.Humanoid.Health = 0

			local accepted, reason = HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("Dead")
		end)
	end)

	describe("HitboxEngine -- a server hitch", function()
		-- A frame far longer than one sample (HitboxEngineConstants' header): the substeps must still make a short
		-- Active window real -- one hit, not none and not two.
		it("lands a short Active window inside one long frame, exactly once", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -4))
			local hits, disconnect = captureHits()

			local base = os.clock()
			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ WindupSeconds = 0.1, ActiveSeconds = 0.05, RecoverySeconds = 0.02 }),
				1,
				0
			)
			HitboxEngine.Step(0.2, base + 0.2)
			disconnect()

			expect(#hits).to.equal(1)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
		end)

		it("does not fast-forward past the frame cap", function()
			-- A stall longer than MaxFrameSeconds is clamped: the swing advances at most that much this frame.
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local base = os.clock()
			local cap = HitboxEngineConstants.MaxFrameSeconds
			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ WindupSeconds = 0, ActiveSeconds = cap * 4, RecoverySeconds = 0 }),
				1,
				0
			)
			HitboxEngine.Step(cap * 10, base + cap)
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

	describe("HitboxEngine -- Weapon attachment resolves onto the equipped Blade", function()
		it("anchors on the weapon's Blade part, not its Handle, when both exist", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			-- Handle sits at the attacker's own position (where a naive "just grip" resolution would
			-- anchor); Blade sits 4 studs out in front, matching this file's usual reach convention.
			equipWeapon(attacker, { HandlePosition = attacker.Root.Position, BladePosition = Vector3.new(0, 5, -4) })
			makeDummy("Target", Vector3.new(0, 5, -4))
			local hits = captureHits()

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ AttachmentPart = "Weapon", Offset = CFrame.new() }),
				1,
				0
			)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)

			-- A box centred on Handle (the attacker's own position) would fall a full stud short of a
			-- target 4 studs out at this definition's Length (6, half-length 3) -- only a Blade-centred
			-- box reaches it, so a hit here is proof of which part actually won.
			expect(#hits).to.equal(1)
		end)

		it("falls back to Handle when the weapon has no part named Blade", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local tool = Instance.new("Tool")
			tool.Name = "HandleOnlySword"
			local handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Anchored = true
			handle.CFrame = CFrame.new(0, 5, -4)
			handle.Parent = tool
			tool.Parent = attacker.Model

			makeDummy("Target", Vector3.new(0, 5, -4))
			local hits = captureHits()

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({ AttachmentPart = "Weapon", Offset = CFrame.new() }),
				1,
				0
			)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)

			expect(#hits).to.equal(1)
		end)

		it("derives Box dimensions from the Blade's own live Size, ignoring BaseDimensions", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			equipWeapon(attacker, { BladePosition = Vector3.new(0, 5, -5), BladeSize = Vector3.new(2, 4, 10) })
			makeDummy("Target", Vector3.new(0, 5, -5))
			local hits = captureHits()

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({
					AttachmentPart = "Weapon",
					Offset = CFrame.new(),
					SizeFromAttachmentPart = true,
					-- Deliberately absurd, to prove they are never read in this mode.
					BaseDimensions = { Width = 999, Height = 999, Length = 999 },
				}),
				1,
				0
			)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)

			expect(#hits).to.equal(1)
			local report = hits[1]
			expect(report.Dimensions.Width).to.equal(2)
			expect(report.Dimensions.Height).to.equal(4)
			expect(report.Dimensions.Length).to.equal(10)
		end)

		it("scales the Blade-derived size by SizeMultiplier, the WeaponReach carrier", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			equipWeapon(attacker, { BladePosition = Vector3.new(0, 5, -5), BladeSize = Vector3.new(2, 4, 10) })
			makeDummy("Target", Vector3.new(0, 5, -5))
			local hits = captureHits()

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({
					AttachmentPart = "Weapon",
					Offset = CFrame.new(),
					SizeFromAttachmentPart = true,
					SizeMultiplier = 2,
					BaseDimensions = { Width = 999, Height = 999, Length = 999 },
				}),
				1,
				0
			)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)

			local report = hits[1]
			assert(report, "must land a hit")
			expect(report.Dimensions.Width).to.equal(4)
			expect(report.Dimensions.Height).to.equal(8)
			expect(report.Dimensions.Length).to.equal(20)
		end)

		it("leaves BaseDimensions in full control when SizeFromAttachmentPart is unset", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			equipWeapon(attacker, { BladePosition = Vector3.new(0, 5, -5), BladeSize = Vector3.new(2, 4, 10) })
			makeDummy("Target", Vector3.new(0, 5, -5))
			local hits = captureHits()

			HitboxEngine.RequestAttack(
				attacker.Id,
				makeDefinition({
					AttachmentPart = "Weapon",
					Offset = CFrame.new(),
					BaseDimensions = { Width = 4, Height = 6, Length = 6 },
				}),
				1,
				0
			)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)

			local report = hits[1]
			assert(report, "must land a hit")
			expect(report.Dimensions.Width).to.equal(4)
			expect(report.Dimensions.Height).to.equal(6)
			expect(report.Dimensions.Length).to.equal(6)
		end)
	end)

	-- AttackConstants.Latency: a player's swing is started a little before its press arrived. The engine owns
	-- the two limits that are about the swing itself.
	describe("HitboxEngine.RequestAttack -- a backdated start", function()
		it("starts the swing at the requested moment and says so", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local requested = os.clock() - 0.05
			local accepted, _, begunAt =
				HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ WindupSeconds = 0.4 }), 1, 0, requested)
			expect(accepted).to.equal(true)
			expect(begunAt).to.be.near(requested, 1e-6)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Windup")
		end)

		it("never backdates so far that the Active window would already be due", function()
			-- Only the windup shortens: a backdated swing can never hit on the frame it arrives.
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local before = os.clock()
			local _, _, begunAt =
				HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ WindupSeconds = 0.1 }), 1, 0, before - 5)
			assert(begunAt, "an accepted swing reports its start")
			expect(begunAt > before - 0.1).to.equal(true)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Windup")
		end)

		it("never backdates into the combatant's previous swing", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local _, _, firstBegun =
				HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ ActiveSeconds = 0.05 }), 1, 0)
			assert(firstBegun, "an accepted swing reports its start")
			HitboxEngine.Step(FRAME, firstBegun + 0.2)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")

			local _, _, secondBegun =
				HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ WindupSeconds = 10 }), 1, 0, firstBegun - 5)
			assert(secondBegun, "an accepted swing reports its start")
			expect(secondBegun >= firstBegun + 0.05 - 1e-6).to.equal(true)
		end)

		it("ignores a start in the future and starts now", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local before = os.clock()
			local _, _, begunAt = HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0, before + 10)
			assert(begunAt, "an accepted swing reports its start")
			expect(begunAt >= before).to.equal(true)
			expect(begunAt <= os.clock()).to.equal(true)
		end)
	end)

	-- HitboxEngineConstants.TargetTrail: a moving target is also tested where the attacker most likely saw it.
	describe("HitboxEngine -- the moving-target allowance", function()
		-- The spec box spans z -1 to -7 in front of the attacker (plus the narrow-phase margin). A target
		-- centred at -8.5 is a stud and a half past its far edge.
		local EDGE_Z = -8.5

		it("still misses a target standing just past the edge", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, EDGE_Z))
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(0)
		end)

		it("catches a target backing away just past the edge", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, EDGE_Z))
			-- Walking away at 18 studs/s: the attacker was looking at it ~1.8 studs closer.
			target.Root.AssemblyLinearVelocity = Vector3.new(0, 0, -18)
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(1)
		end)

		it("does not reach AHEAD of a target that is closing in", function()
			-- The trail is only ever behind a body, along its own motion: one walking toward the attacker was
			-- further away a moment ago, not closer.
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, EDGE_Z))
			target.Root.AssemblyLinearVelocity = Vector3.new(0, 0, 18)
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, os.clock() + 0.01)
			disconnect()

			expect(#hits).to.equal(0)
		end)
	end)
	-- HitboxEngineConstants.LagCompensation: a player's swing also tests a body where that player saw it.
	describe("HitboxEngine -- lag-compensated hits", function()
		local INSIDE_Z = -5
		-- Far past the box's far edge (-7) and past anything the moving-target allowance could reach.
		local GONE_Z = -11.5

		-- Records the target inside the box for a few frames, then moves it out and records a few more, so the
		-- history says where it was a moment ago. Returns the clock the swing is sampled at.
		local function walkOut(target: any, base: number): number
			for frame = 0, 5 do
				HitboxEngine.Step(FRAME, base + frame * FRAME)
			end
			target.Root.CFrame = CFrame.new(0, 5, GONE_Z)
			for frame = 6, 9 do
				HitboxEngine.Step(FRAME, base + frame * FRAME)
			end
			return base + 10 * FRAME
		end

		it("hits a target where a lagged attacker saw it, though it has since moved out", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, INSIDE_Z))
			-- 200 ms of round trip: a 0.1 s one-way trip plus the replication buffer, capped at 0.15 s.
			NetworkLatency.SetResolver(function(model: Model)
				return if model == attacker.Model then 0.2 else 0
			end)
			local swingAt = walkOut(target, os.clock())
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, swingAt)
			disconnect()

			expect(#hits).to.equal(1)
		end)

		it("rewinds nothing for an attacker with no connection (a bot, a dummy)", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, INSIDE_Z))
			local swingAt = walkOut(target, os.clock())
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, swingAt)
			disconnect()

			expect(#hits).to.equal(0)
			expect(HitboxEngine.RewindFor(attacker.Model)).to.equal(0)
		end)

		it("caps the rewind on the victim's side, whatever the attacker's ping", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			NetworkLatency.SetResolver(function()
				return 3
			end)
			expect(HitboxEngine.RewindFor(attacker.Model)).to.equal(
				HitboxEngineConstants.LagCompensation.MaxRewindSeconds
			)
		end)

		it("does not reach a body that was never where the attacker looked", function()
			-- Rewound 0.15 s, the target was still out of the box: it left more than the cap ago.
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, INSIDE_Z))
			NetworkLatency.SetResolver(function(model: Model)
				return if model == attacker.Model then 0.2 else 0
			end)
			local base = os.clock()
			HitboxEngine.Step(FRAME, base)
			target.Root.CFrame = CFrame.new(0, 5, GONE_Z)
			for frame = 1, 20 do
				HitboxEngine.Step(FRAME, base + frame * FRAME)
			end
			local hits, disconnect = captureHits()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({}), 1, 0)
			HitboxEngine.Step(FRAME, base + 21 * FRAME)
			disconnect()

			expect(#hits).to.equal(0)
		end)
	end)

	describe("HitboxEngine -- substep count", function()
		it("divides an ordinary 60Hz Heartbeat into two substeps, not three", function()
			-- Real Heartbeats run a hair over 1/60; a bare ceil gave 3 for every one of these.
			for _, frame in { 1 / 60, 0.01667, 0.0168, 0.017 } do
				expect(HitboxEngine.SubstepsFor(frame)).to.equal(2)
			end
		end)

		it("still subdivides a genuinely long frame, up to the cap", function()
			expect(HitboxEngine.SubstepsFor(1 / 30)).to.equal(4)
			expect(HitboxEngine.SubstepsFor(0.25)).to.equal(HitboxEngineConstants.MaxSubstepsPerFrame)
			expect(HitboxEngine.SubstepsFor(0)).to.equal(1)
		end)
	end)

end
