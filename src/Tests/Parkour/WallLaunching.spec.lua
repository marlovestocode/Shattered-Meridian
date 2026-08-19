--!strict
-- Covers States/WallLaunching.lua's entry gate and its launch.
--
-- NOT Instance-free, deliberately, and for the same reason Tests/Parkour/ParkourMotor.spec.lua gives:
-- Enter's launch goes through StateSupport.TryJump into the real ParkourMotor, so a stubbed context
-- could only ever assert against this file's own arithmetic. A real Humanoid + HumanoidRootPart makes
-- ApplyImpulse's write to AssemblyLinearVelocity the actual thing under test. Cleans up its rig after
-- every test, the same rigor ParkourMotor.spec.lua documents for the same reason: a leaked character in
-- the test place would be visible to every spec that runs after it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMotor = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.ParkourMotor)
local InputBuffer = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.InputBuffer)
local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)

local WALL_LAUNCH = ParkourConstants.WallLaunch

local function findDefinition(id: string)
	for _, definition in States do
		if definition.Id == id then
			return definition
		end
	end
	error(`no state definition registered for {id}`)
end

local WallLaunching = findDefinition("WallLaunching")
local canEnter = WallLaunching.CanEnter
local wallLaunchingEnter = assert(WallLaunching.Enter, "States/WallLaunching.lua must define Enter")

type Rig = { Character: Model, Humanoid: Humanoid, RootPart: BasePart }

local function makeRig(): Rig
	local character = Instance.new("Model")
	character.Name = "WallLaunchingSpecCharacter"

	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Size = Vector3.new(2, 2, 1)
	rootPart.CFrame = CFrame.lookAt(Vector3.new(0, 50, 0), Vector3.new(0, 50, -1))
	rootPart.Anchored = false
	rootPart.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = 2
	humanoid.Parent = character

	character.PrimaryPart = rootPart
	character.Parent = Workspace
	return { Character = character, Humanoid = humanoid, RootPart = rootPart }
end

local function destroyRig(rig: Rig): ()
	ParkourMotor.Unbind()
	rig.Character:Destroy()
end

local TALL_WALL = { Found = true, Height = math.huge }
local NO_OBSTACLE = { Found = false, Height = 0 }
local MANTLEABLE = { Found = true, Height = ParkourConstants.Obstacle.MantleMaxHeight }

-- Everything upstream of the gate under test, set to values that PASS.
local function makeContext(now: number): any
	return {
		RootPart = nil :: any,
		Now = now,
		DeltaTime = 1 / 60,
		StateElapsed = 0,
		CurrentStateId = "Idle",
		MoveIntent = Vector3.zero,
		MoveDirection = Vector3.zero,
		Momentum = 0,
		VerticalVelocity = 0,
		InCombat = false,
		Ground = { Grounded = true, NearGround = true, Distance = 0, Normal = Vector3.yAxis },
		Obstacle = TALL_WALL,
		WallLaunchDashBoostUntil = 0,
		LandingSeverity = nil,
		FallHeight = 0,
	}
end

return function()
	describe("WallLaunching.CanEnter", function()
		-- StateSupport.JumpQueued reads ParkourMotor.IsJumpEnabled(), which requires a BOUND Humanoid
		-- (it returns false, unconditionally, while unbound) -- every one of these needs the real rig
		-- for exactly the reason Tests/Parkour/ParkourMotor.spec.lua's own header gives, not just the
		-- Enter tests below.
		local clock = 2000
		local function nextNow(): number
			clock += 10
			return clock
		end

		it("accepts grounded, facing a wall too tall to vault or mantle, with jump pressed", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			local now = nextNow()
			local context = makeContext(now)
			InputBuffer.PressJump(now)
			expect(canEnter(context)).to.equal(true)
			InputBuffer.Clear()
			destroyRig(rig)
		end)

		it("refuses with no wall ahead at all", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			local now = nextNow()
			local context = makeContext(now)
			context.Obstacle = NO_OBSTACLE
			InputBuffer.PressJump(now)
			local allowed, reason = canEnter(context)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NoWallAhead")
			InputBuffer.Clear()
			destroyRig(rig)
		end)

		it("refuses a wall short enough to vault or mantle -- that is a different move entirely", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			local now = nextNow()
			local context = makeContext(now)
			context.Obstacle = MANTLEABLE
			InputBuffer.PressJump(now)
			local allowed, reason = canEnter(context)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NoWallAhead")
			InputBuffer.Clear()
			destroyRig(rig)
		end)

		it("refuses while airborne -- deliberately unlike Jumping, this move has no coyote window", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			local now = nextNow()
			local context = makeContext(now)
			context.Ground.Grounded = false
			InputBuffer.PressJump(now)
			local allowed, reason = canEnter(context)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NotGrounded")
			InputBuffer.Clear()
			destroyRig(rig)
		end)

		it("refuses with no buffered jump", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			InputBuffer.Clear()
			local allowed, reason = canEnter(makeContext(nextNow()))
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NoJumpInput")
			destroyRig(rig)
		end)

		it("still accepts while in combat -- a jump variant, not combat-gated, exactly like Jumping", function()
			-- ParkourConstants.CombatGate.BlockedStates has no "WallLaunching" entry, matching
			-- States/Jumping.lua's own precedent (that file does not call StateSupport.CombatBlocks
			-- either). This is the record of that being a decision, not an omission.
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			local now = nextNow()
			local context = makeContext(now)
			context.InCombat = true
			InputBuffer.PressJump(now)
			expect(canEnter(context)).to.equal(true)
			InputBuffer.Clear()
			destroyRig(rig)
		end)
	end)

	describe("WallLaunching.Enter", function()
		it("launches up and backward, and opens the dash-chain boost window", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local context = makeContext(3000)
			context.RootPart = rig.RootPart
			InputBuffer.PressJump(3000)

			wallLaunchingEnter(context)

			expect(rig.RootPart.AssemblyLinearVelocity.Y).to.equal(WALL_LAUNCH.VerticalVelocity)
			-- Facing -Z (see makeRig), so away-from-the-wall is +Z.
			expect(rig.RootPart.AssemblyLinearVelocity.Z > 0).to.equal(true)
			expect(rig.RootPart.AssemblyLinearVelocity.Magnitude).to.equal(
				Vector3.new(0, WALL_LAUNCH.VerticalVelocity, WALL_LAUNCH.BackwardSpeed).Magnitude
			)
			expect(context.WallLaunchDashBoostUntil).to.equal(3000 + WALL_LAUNCH.DashBoostWindowSeconds)

			InputBuffer.Clear()
			destroyRig(rig)
		end)

		it("cancels a stale fall's landing cost, same courtesy every launch in this framework performs", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local context = makeContext(3100)
			context.RootPart = rig.RootPart
			context.LandingSeverity = "Hard"
			context.FallHeight = 40
			InputBuffer.PressJump(3100)

			wallLaunchingEnter(context)

			expect(context.LandingSeverity).to.equal(nil)
			expect(context.FallHeight).to.equal(0)

			InputBuffer.Clear()
			destroyRig(rig)
		end)
	end)

	describe("WallLaunch tuning", function()
		it("launches higher than an ordinary jump, but not by an ordinary jump's worth", function()
			local JUMP = ParkourConstants.Jump
			expect(WALL_LAUNCH.VerticalVelocity > JUMP.JumpVelocity).to.equal(true)
			expect(WALL_LAUNCH.VerticalVelocity < JUMP.JumpVelocity * 1.5).to.equal(true)
		end)

		it("gives enough window to actually look up and press the dash key", function()
			expect(WALL_LAUNCH.DashBoostWindowSeconds >= 0.4).to.equal(true)
			expect(WALL_LAUNCH.DashBoostWindowSeconds <= 1.5).to.equal(true)
		end)
	end)
end
