--!strict
-- Covers the CATCH half of States/WallRunning.lua's CanEnter -- the head-on wall arrival that the
-- wall-RUN refuses by construction and that, before the catch existed, nothing claimed at all (so
-- Roblox's own collision response resolved it and the character bounced off).
--
-- Built the same way Tests/Parkour/StateFacingGates.spec builds its contexts and for the same reason:
-- CanEnter is contractually side-effect free (see StateMachine.lua) and reads everything from the
-- context handed to it, so a hand-built context is an honest end-to-end assertion of the real
-- predicate without a live character, a probe pass or a frame loop.
--
-- THE CENTRAL PROPERTY these tests exist to pin is that the run and the catch PARTITION the approach
-- space: every wall that is otherwise usable is either a run or a catch, never both and never neither.
-- That is why the catch reads WallRun.MaxApproachAngleDegrees rather than authoring a threshold of its
-- own, and it is the thing a future retune could silently break.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)

local WALLRUN = ParkourConstants.WallRun
local CATCH = WALLRUN.Catch

local function findDefinition(id: string)
	for _, definition in States do
		if definition.Id == id then
			return definition
		end
	end
	error(`no state definition registered for {id}`)
end

local WallRunning = findDefinition("WallRunning")

-- A real BasePart: the predicate reads both CFrame.LookVector and AssemblyLinearVelocity off it, and a
-- stub with hand-written fields would assert against our own arithmetic rather than the engine's.
local function makeRootPart(facing: Vector3, velocity: Vector3): BasePart
	local part = Instance.new("Part")
	part.Size = Vector3.new(2, 5, 1)
	part.CFrame = CFrame.lookAt(Vector3.zero, facing.Unit)
	part.AssemblyLinearVelocity = velocity
	return part
end

-- The wall face is at -Z, so its OUTWARD normal points +Z, back at whoever is approaching it.
local WALL_NORMAL = Vector3.new(0, 0, 1)
-- Straight at that face.
local HEAD_ON = Vector3.new(0, 0, -1)
-- Along it. The tangent of a +Z-normal wall is the X axis (UP cross normal), so this is a clean run.
local ALONGSIDE = Vector3.new(1, 0, 0)

-- Everything upstream of the approach/closing-speed gates set to values that PASS, so any refusal a
-- test sees is the gate that test is about. `travel` drives both MoveDirection and the tangent, and
-- `speed` is the closing speed applied along travel.
local function makeContext(travel: Vector3, speed: number): any
	local wall = {
		Found = true,
		Distance = 2,
		Position = Vector3.zero,
		Normal = WALL_NORMAL,
		Tangent = ParkourMath.WallTangent(WALL_NORMAL, travel),
		TiltAngle = 0,
		Instance = nil,
		WallRunAllowed = true,
		BounceScale = 1,
		SampledAt = 0,
	}
	local absentWall = {
		Found = false,
		Distance = 0,
		Position = Vector3.zero,
		Normal = Vector3.zero,
		Tangent = Vector3.zero,
		TiltAngle = 90,
		Instance = nil,
		WallRunAllowed = false,
		BounceScale = 1,
		SampledAt = 0,
	}
	return {
		-- Facing along travel throughout: this spec is about approach angle and closing speed, and the
		-- facing gate has its own coverage in StateFacingGates.spec.
		RootPart = makeRootPart(travel, travel.Unit * speed),
		Now = os.clock(),
		MoveDirection = travel,
		MoveIntent = travel,
		Momentum = WALLRUN.MinEntrySpeed + 6,
		WallRunChain = 0,
		WallJumpChain = 0,
		InCombat = false,
		LastWallInstance = nil,
		LastWallLeftAt = 0,
		Ground = { Grounded = false, NearGround = false, Distance = 40 },
		WallLeft = wall,
		WallRight = absentWall,
		-- The debug verdict strings this spec asserts on are only produced when something is going to
		-- read them (ParkourContext.DebugEnabled -- the F6 overlay, or Debug.LogWallCatch). A live
		-- client with neither pays no string.format per frame; a test that asserts on the string has to
		-- ask for it. The "writes no verdict at all" case below covers the other side.
		DebugEnabled = true,
	}
end

return function()
	describe("the head-on arrival that used to bounce", function()
		it("is accepted", function()
			-- The whole bug report: jumping into a wall at speed. Before the catch this refused with
			-- ApproachAngleTooSteep and nothing else in the framework claimed the contact.
			local allowed, reason = WallRunning.CanEnter(makeContext(HEAD_ON, CATCH.MinClosingSpeed + 10))
			expect(reason).to.equal(nil)
			expect(allowed).to.equal(true)
		end)

		it("is refused when the character is only drifting into the wall", function()
			-- A gentle brush against a corner is not a slam, and catching it would stick the player to
			-- every wall they touch.
			local allowed, reason = WallRunning.CanEnter(makeContext(HEAD_ON, CATCH.MinClosingSpeed - 5))
			expect(allowed).to.equal(false)
			expect(reason).to.equal("TooSlowToCatch")
		end)

		it("still refuses when the surface is not one the framework may use", function()
			local context = makeContext(HEAD_ON, CATCH.MinClosingSpeed + 10)
			context.WallLeft.WallRunAllowed = false
			local allowed = WallRunning.CanEnter(context)
			expect(allowed).to.equal(false)
		end)

		it("still refuses a surface too far from vertical to be a wall", function()
			-- A steep ramp is approached head-on at speed constantly. Catching one would stop players
			-- dead at the foot of every slope in the game.
			local context = makeContext(HEAD_ON, CATCH.MinClosingSpeed + 10)
			context.WallLeft.TiltAngle = WALLRUN.MaxSurfaceTiltDegrees + 5
			local allowed = WallRunning.CanEnter(context)
			expect(allowed).to.equal(false)
		end)
	end)

	describe("the run and the catch partition the approach space", function()
		it("takes a glancing approach as a run, not a catch", function()
			-- Same wall, same speed, different approach. This one has to stay a wall-run -- the catch
			-- must never be able to swallow an entry the run was going to take.
			local allowed, reason = WallRunning.CanEnter(makeContext(ALONGSIDE, CATCH.MinClosingSpeed + 10))
			expect(reason).to.equal(nil)
			expect(allowed).to.equal(true)
		end)

		it("keeps a fast run PAST a wall out of the catch entirely", function()
			-- The distinction the catch gates on closing speed to make. Travelling along the face at
			-- speed means high momentum and almost NO speed along the normal; gating on momentum instead
			-- would have caught this, turning every wall-run approach into a stick.
			local context = makeContext(ALONGSIDE, 40)
			-- Force the run to refuse for an unrelated reason, so what is left is the catch's own answer
			-- about a body moving fast parallel to a wall.
			context.WallLeft.Tangent = ParkourMath.WallTangent(WALL_NORMAL, ALONGSIDE)
			context.MoveDirection = ALONGSIDE
			local closing = ParkourMath.Flatten(context.RootPart.AssemblyLinearVelocity)
				:Dot(-ParkourMath.Flatten(WALL_NORMAL).Unit)
			expect(closing < CATCH.MinClosingSpeed).to.equal(true)
		end)

		it("has no angle band where both a run and a catch could qualify", function()
			-- The catch tests `>` against the same constant the run tests `<=` against. Asserted as a
			-- property over the whole range rather than at the boundary, so a future retune that
			-- introduces a gap or an overlap fails here rather than in a playtest.
			for degrees = 0, 180, 5 do
				local radians = math.rad(degrees)
				-- Rotate travel around Y, from along the wall (X) toward into it (-Z).
				local travel = Vector3.new(math.cos(radians), 0, -math.sin(radians))
				local tangent = ParkourMath.WallTangent(WALL_NORMAL, travel)
				local approach = ParkourMath.ApproachAngle(travel, tangent)
				local isRun = approach <= WALLRUN.MaxApproachAngleDegrees
				local isCatch = approach > WALLRUN.MaxApproachAngleDegrees
				expect(isRun ~= isCatch).to.equal(true, `approach {approach} at {degrees} degrees`)
			end
		end)
	end)

	describe("the debug readout", function()
		it("reports the measurements behind a near miss, not just the verdict", function()
			-- "TooSlowToCatch" alone cannot tell a player who was nearly fast enough from one who was
			-- barely moving, and that difference is the whole question behind "why didn't it catch".
			local context = makeContext(HEAD_ON, CATCH.MinClosingSpeed - 5)
			WallRunning.CanEnter(context)
			expect(context.DebugWallCatch).to.be.a("string")
			expect(string.find(context.DebugWallCatch, "TooSlowToCatch", 1, true)).to.be.ok()
			expect(string.find(context.DebugWallCatch, "closing", 1, true)).to.be.ok()
			expect(string.find(context.DebugWallCatch, "approach", 1, true)).to.be.ok()
		end)

		it("says ready when the catch would fire", function()
			local context = makeContext(HEAD_ON, CATCH.MinClosingSpeed + 10)
			WallRunning.CanEnter(context)
			expect(string.match(context.DebugWallCatch, "^ready")).to.be.ok()
		end)

		it("distinguishes a gate that refused before any wall was looked at", function()
			-- Standing on the ground is the resting state, not a fault, and it must not leave the last
			-- geometric measurement on screen reading like the catch is nearly working. This is the
			-- refusal the player actually hits when they RUN at a wall instead of jumping into it.
			local context = makeContext(HEAD_ON, CATCH.MinClosingSpeed + 10)
			context.Ground = { Grounded = true, NearGround = true, Distance = 0 }
			local allowed, reason = WallRunning.CanEnter(context)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("Grounded")
			expect(context.DebugWallCatch).to.equal("blocked  Grounded")
		end)

		it("writes no verdict at all when nothing is going to read one", function()
			-- The gate that keeps CanEnter free for the overwhelming majority of frames: StateMachine
			-- evaluates it for every higher-priority state on every frame, so an ungated string.format
			-- here is one heap allocation per frame per client, forever, for a value only
			-- ParkourDebug.Update reads -- and that returns immediately when the overlay is closed.
			local context = makeContext(HEAD_ON, CATCH.MinClosingSpeed + 10)
			context.DebugEnabled = false
			context.DebugWallCatch = nil

			WallRunning.CanEnter(context)
			expect(context.DebugWallCatch).to.equal(nil)

			-- And the refusal path, which writes through a different function.
			local grounded = makeContext(HEAD_ON, CATCH.MinClosingSpeed + 10)
			grounded.DebugEnabled = false
			grounded.DebugWallCatch = nil
			grounded.Ground = { Grounded = true, NearGround = true, Distance = 0 }

			WallRunning.CanEnter(grounded)
			expect(grounded.DebugWallCatch).to.equal(nil)
		end)
	end)

	describe("gates the catch must NOT inherit from the run", function()
		it("catches close to the ground, where a wall-RUN would be refused", function()
			-- MinGroundClearance exists because "wall-running six inches off the floor is just running".
			-- A catch carries you nowhere -- it is the difference between stopping dead and pinging off
			-- -- and that is just as real one stud up as ten. Inheriting the run's clearance refused
			-- every catch taken on the way up out of a jump, which is most of them.
			local context = makeContext(HEAD_ON, CATCH.MinClosingSpeed + 10)
			context.Ground = { Grounded = false, NearGround = true, Distance = WALLRUN.MinGroundClearance - 1 }
			local allowed, reason = WallRunning.CanEnter(context)
			expect(reason).to.equal(nil)
			expect(allowed).to.equal(true)
		end)

		it("still refuses a wall-RUN that close to the ground", function()
			-- Guards the assertion above against being satisfied by the clearance check having been
			-- deleted outright rather than scoped to the run.
			local context = makeContext(ALONGSIDE, CATCH.MinClosingSpeed + 10)
			context.Ground = { Grounded = false, NearGround = true, Distance = WALLRUN.MinGroundClearance - 1 }
			local allowed, reason = WallRunning.CanEnter(context)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("TooCloseToGround")
		end)
	end)

	describe("the head-on probe stays alive for the catch's whole life", function()
		-- The one-frame catch. It entered from Falling (where EnvironmentProbe's diagonal fallback is
		-- live and is the ONLY cast that can see a wall dead ahead), and lost that wall on the very next
		-- frame once CurrentStateId had become "WallRunning" and the fallback switched itself off. The
		-- flag below is what carves the catch out of that cutoff, so these assert the contract from both
		-- ends rather than the flag's value in isolation.
		local function allowsDiagonal(currentStateId: string?, wallCatchActive: boolean): boolean
			-- Mirrors EnvironmentProbe's own expression. Restated rather than imported because the
			-- expression is a local inside a 1500-line frame function with no seam to reach it by -- the
			-- coupling this pins is to the RULE, and a change to the rule that does not change this
			-- fails the review rather than the test, which is the honest bound on what this can catch.
			return currentStateId ~= "WallRunning" or wallCatchActive
		end

		it("keeps the fallback on while the catch holds the wall", function()
			expect(allowsDiagonal("WallRunning", true)).to.equal(true)
		end)

		it("still denies it to an ordinary wall-run", function()
			-- Guards the exemption against being written as "always on", which would hand the run's
			-- corner logic a perpendicular wall further ahead and swing its tangent ninety degrees.
			expect(allowsDiagonal("WallRunning", false)).to.equal(false)
		end)

		it("leaves every other state unaffected", function()
			-- Falling is where a catch is entered FROM, so the fallback must be live there regardless.
			expect(allowsDiagonal("Falling", false)).to.equal(true)
			expect(allowsDiagonal("Jumping", false)).to.equal(true)
		end)
	end)

	describe("tuning", function()
		it("keeps the catch short enough to be a beat rather than a perch", function()
			expect(CATCH.MaxDurationSeconds > 0).to.equal(true)
			-- Longer than the run's own duration would make slamming into a wall strictly better than
			-- running along one, which inverts the skill ordering the whole feature sits inside.
			expect(CATCH.MaxDurationSeconds < WALLRUN.MaxDurationSeconds).to.equal(true)
		end)

		it("costs most of the run-up rather than preserving it", function()
			-- The kick that may follow reads context.Momentum for its carry. A catch that kept full speed
			-- would be the cheapest way through a corridor instead of the cost of misjudging one.
			expect(CATCH.MomentumRetainFraction > 0).to.equal(true)
			expect(CATCH.MomentumRetainFraction < 0.5).to.equal(true)
		end)

		it("requires a genuinely fast arrival -- comfortably above an ordinary walk", function()
			-- The regression this guards: MinClosingSpeed used to equal Locomotion.WalkSpeed exactly
			-- (18 == 18), which is not a margin at all -- an ordinary walk straight at a wall closes at
			-- very close to WalkSpeed and could trip the gate on a frame of input noise, which read in
			-- play as "I just walked into it and got stuck." A deliberate sprint must still catch.
			local Locomotion = ParkourConstants.Locomotion
			expect(CATCH.MinClosingSpeed > Locomotion.WalkSpeed + 3).to.equal(true)
			expect(CATCH.MinClosingSpeed < Locomotion.SprintSpeed).to.equal(true)
		end)
	end)
end
