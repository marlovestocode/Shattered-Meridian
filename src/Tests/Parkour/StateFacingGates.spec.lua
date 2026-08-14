--!strict
-- Covers the FACING gates on the two automatic-ish traversals that had none: States/LedgeHanging.lua's
-- grab and States/WallRunning.lua's attach.
--
-- WHY THESE NEED A SPEC AT ALL, when Tests/Parkour/StateSupport.spec already asserts the shared
-- IsMovingToward helper: the helper being correct was never the problem. Mantling/Vaulting called it;
-- LedgeHanging and WallRunning did not, and a helper nobody calls refuses nothing. So these tests
-- deliberately go through the real CanEnter predicates rather than the geometry helpers underneath
-- them -- the thing being asserted is that the gate is WIRED IN, which is exactly the class of bug a
-- unit test of the helper cannot see.
--
-- Both gates exist because shift lock (Client/Camera/ShiftLockCamera.lua) decouples travel direction
-- from facing: WASD is camera-relative with AutoRotate off, so a backpedal or a strafe moves the
-- character into geometry they are not looking at. Every "backward" case below is therefore built the
-- way shift lock actually produces it -- facing one way, travel/tangent another -- rather than by
-- reversing both together, which is the mistake that would make these tests pass against the
-- pre-fix code.
--
-- The contexts are built by hand rather than driven through ParkourController, because CanEnter is
-- contractually side-effect free (see StateMachine.lua) and takes everything it reads from the context
-- it is handed. That makes these honest end-to-end assertions of the predicate without needing a live
-- character, a probe pass, or a frame loop.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)

local LEDGE = ParkourConstants.Ledge
local WALLRUN = ParkourConstants.WallRun

-- A real BasePart, because RootPart.CFrame.LookVector is precisely what both gates read and a stub
-- table with a hand-written LookVector would be asserting against our own arithmetic rather than the
-- engine's. Oriented with CFrame.lookAt so "facing" in each test below means what it says.
local function makeRootPart(facing: Vector3): BasePart
	local part = Instance.new("Part")
	part.Size = Vector3.new(2, 5, 1)
	part.CFrame = CFrame.lookAt(Vector3.zero, facing.Unit)
	return part
end

local function findDefinition(id: string)
	for _, definition in States do
		if definition.Id == id then
			return definition
		end
	end
	error(`no state definition registered for {id}`)
end

local LedgeHanging = findDefinition("LedgeHanging")
local WallRunning = findDefinition("WallRunning")

-- Everything upstream of the facing gate, set to values that PASS -- so any refusal these tests see is
-- the facing gate and nothing else. Each test then overrides only the direction it is about.
local function makeLedgeContext(facing: Vector3, wallNormal: Vector3): any
	return {
		RootPart = makeRootPart(facing),
		Now = os.clock(),
		VerticalVelocity = -10,
		Assists = { CoyoteTime = true, JumpBuffer = true, AutoVault = true, LedgeAssist = true, StepAssist = true },
		Ground = { Grounded = false, NearGround = false, Distance = 40 },
		Ledge = {
			Found = true,
			Allowed = true,
			HasHangSpace = true,
			HasStandingSpace = true,
			EdgePosition = Vector3.new(0, 6, -3),
			WallNormal = wallNormal,
			Instance = nil,
			SampledAt = 0,
		},
	}
end

-- Same idea for the wall-run. `travel` drives the tangent through the real ParkourMath.WallTangent
-- rather than a hand-authored vector, because the whole point of the new check is that the tangent
-- AGREES with travel by construction -- authoring the tangent directly would quietly discard the
-- property that makes the travel-only check insufficient.
local function makeWallRunContext(facing: Vector3, travel: Vector3, wallNormal: Vector3): any
	local tangent = ParkourMath.WallTangent(wallNormal, travel)
	local wall = {
		Found = true,
		Distance = 2,
		Normal = wallNormal,
		Tangent = tangent,
		TiltAngle = 0,
		Instance = nil,
		WallRunAllowed = true,
		BounceScale = 1,
		SampledAt = 0,
	}
	local absentWall = {
		Found = false,
		Distance = 0,
		Normal = Vector3.zero,
		Tangent = Vector3.zero,
		TiltAngle = 90,
		Instance = nil,
		WallRunAllowed = false,
		BounceScale = 1,
		SampledAt = 0,
	}
	return {
		RootPart = makeRootPart(facing),
		Now = os.clock(),
		MoveDirection = travel,
		MoveIntent = travel,
		Momentum = WALLRUN.MinEntrySpeed + 6,
		WallRunChain = 0,
		-- Zero rather than absent: CanEnter reads it to decide whether the entry-speed requirement
		-- applies at all (it is waived mid-chain), and every fixture here is about a FIRST attach, where
		-- the requirement is fully in force.
		WallJumpChain = 0,
		LastWallInstance = nil,
		LastWallLeftAt = 0,
		Ground = { Grounded = false, NearGround = false, Distance = 40 },
		-- Wall on the character's left, which is the side the -X normal below describes.
		WallLeft = wall,
		WallRight = absentWall,
	}
end

return function()
	describe("LedgeHanging.CanEnter facing gate", function()
		-- Wall face at -Z, so its OUTWARD normal (what LedgeProbe.WallNormal reports) points +Z, back
		-- at whoever is approaching it.
		local WALL_NORMAL = Vector3.new(0, 0, 1)

		it("grabs an edge the character is looking straight at", function()
			-- This also covers the strafe-past-a-ledge-while-staring-at-it reach that
			-- EnvironmentProbe.probeLedge's two-direction search exists to serve, and that a facing gate
			-- is most at risk of breaking: that case differs only in TRAVEL, which this predicate
			-- deliberately does not read -- the gate is facing-only, so however the edge was found, a
			-- character looking at it may take it.
			local allowed = LedgeHanging.CanEnter(makeLedgeContext(Vector3.new(0, 0, -1), WALL_NORMAL))
			expect(allowed).to.equal(true)
		end)

		it("refuses an edge directly BEHIND the character -- the shift-lock backpedal grab", function()
			-- Facing +Z (away from the face) while the probe found a wall whose outward normal is also
			-- +Z. Under shift lock this is a player holding S: travel carries them into a wall at their
			-- back, which is what found the edge, while they look the other way entirely. Before the
			-- gate this grabbed -- automatically, with no button, mid-fall.
			local allowed, reason = LedgeHanging.CanEnter(makeLedgeContext(Vector3.new(0, 0, 1), WALL_NORMAL))
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NotFacingLedge")
		end)

		it("refuses an edge purely to the character's SIDE", function()
			local allowed, reason = LedgeHanging.CanEnter(makeLedgeContext(Vector3.new(1, 0, 0), WALL_NORMAL))
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NotFacingLedge")
		end)

		it("tolerates a fall that arrives off-axis but still oriented at the face", function()
			-- A catch is not a deliberate approach: the threshold is deliberately wider than the
			-- obstacle one, and a plausible arcing fall must not be refused.
			local radians = math.rad(LEDGE.MaxGrabFacingAngleDegrees - 10)
			local facing = Vector3.new(math.sin(radians), 0, -math.cos(radians))
			expect(LedgeHanging.CanEnter(makeLedgeContext(facing, WALL_NORMAL))).to.equal(true)
		end)
	end)

	describe("WallRunning.CanEnter facing gate", function()
		-- Wall on the character's left: its outward normal points back at them, i.e. +X.
		local WALL_NORMAL = Vector3.new(1, 0, 0)

		it("attaches when running the way the character is looking", function()
			local forward = Vector3.new(0, 0, -1)
			expect(WallRunning.CanEnter(makeWallRunContext(forward, forward, WALL_NORMAL))).to.equal(true)
		end)

		it("refuses a BACKWARDS run -- travel down the wall, facing up it", function()
			-- The case the pre-existing travel-vs-tangent check structurally cannot catch:
			-- ParkourMath.WallTangent orients the tangent to agree with travel, so travel-vs-tangent is
			-- ~0 whichever way along the wall the character moves. Only facing distinguishes them.
			local allowed, reason =
				WallRunning.CanEnter(makeWallRunContext(Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), WALL_NORMAL))
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NotFacingRunDirection")
		end)

		it("refuses facing square into the wall while travelling along it", function()
			local allowed, reason =
				WallRunning.CanEnter(makeWallRunContext(Vector3.new(-1, 0, 0), Vector3.new(0, 0, -1), WALL_NORMAL))
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NotFacingRunDirection")
		end)

		it("does not disturb the pre-existing travel-vs-tangent refusal", function()
			-- Running straight INTO the wall, facing the same way. The older check owns this one, and
			-- the new gate must not steal its refusal reason -- the debug overlay's whole value is that
			-- the two stay distinguishable.
			local intoWall = Vector3.new(-1, 0, 0)
			local allowed, reason = WallRunning.CanEnter(makeWallRunContext(intoWall, intoWall, WALL_NORMAL))
			expect(allowed).to.equal(false)
			expect(reason).to.equal("ApproachAngleTooSteep")
		end)
	end)

	describe("the facing thresholds themselves", function()
		it("keeps every facing gate strictly inside a right angle", function()
			-- The property that makes "sideways" a refusal rather than a pass. A threshold at or past 90
			-- would readmit exactly the strafe-into-geometry-you-aren't-looking-at cases these gates
			-- exist to refuse, without any test above necessarily failing.
			expect(LEDGE.MaxGrabFacingAngleDegrees < 90).to.equal(true)
			expect(WALLRUN.MaxFacingAngleDegrees < 90).to.equal(true)
			expect(LEDGE.GrabDirectionMaxSplitDegrees < 90).to.equal(true)
		end)

		it("leaves the grab looser than the deliberate-approach traversals", function()
			-- A catch tolerates more off-axis than a mantle the player walked into on purpose. If these
			-- ever invert it is a tuning mistake, not a deliberate choice.
			expect(LEDGE.MaxGrabFacingAngleDegrees > ParkourConstants.Obstacle.MaxApproachAngleDegrees).to.equal(true)
		end)

		it("keeps the ledge search window above the split it is paired with", function()
			-- GrabDirectionSplitDegrees decides when facing is worth a SECOND cast; the max decides when
			-- travel stops being worth a first one. Inverting them would mean the two fight over the
			-- same divergence band.
			expect(LEDGE.GrabDirectionMaxSplitDegrees > LEDGE.GrabDirectionSplitDegrees).to.equal(true)
		end)
	end)
end
