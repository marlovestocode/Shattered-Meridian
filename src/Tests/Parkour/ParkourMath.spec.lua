--!strict
-- Covers Shared/Parkour/ParkourMath.lua -- the pure decision layer every parkour state runs on.
-- Instance-free by design (see that module's own header), so every case below is plain arithmetic
-- with no character, no Workspace and no yielding.
--
-- Weighted toward the cases that are easy to get wrong and expensive to notice in a playtest: the
-- degenerate vectors that produce NaN, the three-regime momentum integrator, the wall tangent's
-- direction agreement, and the exact boundaries of the two assist windows.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)

local function expectClose(actual: number, expected: number, tolerance: number?): ()
	local allowed = tolerance or 1e-4
	expect(math.abs(actual - expected) <= allowed).to.equal(true)
end

return function()
	describe("ParkourMath.SafeUnit", function()
		it("returns the unit vector for a normal input", function()
			local result = ParkourMath.SafeUnit(Vector3.new(0, 0, -5), Vector3.zero)
			expectClose(result.Z, -1)
			expectClose(result.Magnitude, 1)
		end)

		it("returns the fallback rather than a NaN vector for a zero input", function()
			local fallback = Vector3.new(1, 0, 0)
			expect(ParkourMath.SafeUnit(Vector3.zero, fallback)).to.equal(fallback)
		end)

		it("never produces NaN components for a near-zero input", function()
			local result = ParkourMath.SafeUnit(Vector3.new(1e-9, 0, 0), Vector3.zero)
			expect(result.X == result.X).to.equal(true)
		end)
	end)

	describe("ParkourMath.Flatten / PlanarSpeed", function()
		it("zeroes the Y component", function()
			expect(ParkourMath.Flatten(Vector3.new(3, 99, 4)).Y).to.equal(0)
		end)

		it("measures planar speed ignoring vertical velocity entirely", function()
			expectClose(ParkourMath.PlanarSpeed(Vector3.new(3, -200, 4)), 5)
		end)
	end)

	describe("ParkourMath.StepToward", function()
		it("never overshoots even across a very large deltaTime", function()
			expect(ParkourMath.StepToward(0, 10, 100, 999)).to.equal(10)
		end)

		it("moves by exactly rate * deltaTime when the gap is larger", function()
			expectClose(ParkourMath.StepToward(0, 100, 50, 0.5), 25)
		end)

		it("steps downward toward a lower target", function()
			expectClose(ParkourMath.StepToward(100, 0, 50, 0.5), 75)
		end)
	end)

	describe("ParkourMath.IntegrateMomentum", function()
		it("accelerates toward the target while input is held", function()
			local result = ParkourMath.IntegrateMomentum(0, 27, true, 85, 55, 14, 0.1)
			expectClose(result, 8.5)
		end)

		it("decelerates toward ZERO -- not toward the target -- when input is released", function()
			-- The distinction that makes releasing the stick mean "stop" rather than "coast to walking
			-- pace": the target is ignored entirely in this regime.
			local result = ParkourMath.IntegrateMomentum(10, 27, false, 85, 55, 14, 0.1)
			expectClose(result, 4.5)
		end)

		it("bleeds overspeed at deceleration PLUS the overspeed decay", function()
			-- 40 -> target 27, with input held. Overspeed regime, so the rate is 55 + 14 = 69.
			local result = ParkourMath.IntegrateMomentum(40, 27, true, 85, 55, 14, 0.1)
			expectClose(result, 33.1)
		end)

		it("treats overspeed identically with or without input held", function()
			local held = ParkourMath.IntegrateMomentum(40, 27, true, 85, 55, 14, 0.1)
			local released = ParkourMath.IntegrateMomentum(40, 27, false, 85, 55, 14, 0.1)
			expectClose(held, released)
		end)
	end)

	describe("ParkourMath.SlopeAngle / SurfaceTilt", function()
		it("reports a flat floor as zero degrees of slope", function()
			expectClose(ParkourMath.SlopeAngle(Vector3.new(0, 1, 0)), 0)
		end)

		it("reports a vertical wall as ninety degrees of slope", function()
			expectClose(ParkourMath.SlopeAngle(Vector3.new(0, 0, 1)), 90)
		end)

		it("reports a vertical wall as ZERO tilt -- the complement, and the wall-run gate", function()
			expectClose(ParkourMath.SurfaceTilt(Vector3.new(0, 0, 1)), 0)
		end)

		it("reports a flat floor as ninety degrees of tilt, disqualifying it from wall-running", function()
			expectClose(ParkourMath.SurfaceTilt(Vector3.new(0, 1, 0)), 90)
		end)
	end)

	describe("ParkourMath.HangPosition", function()
		-- A wall face on the -Z side of the character: its outward normal points back at them, +Z.
		local wallNormal = Vector3.new(0, 0, 1)
		local edge = Vector3.new(0, 10, 0)

		it("hangs the root below the edge by the vertical offset", function()
			expectClose(ParkourMath.HangPosition(edge, wallNormal, -2.4, -0.85).Y, 7.6)
		end)

		it("backs the root off the wall face, never into it", function()
			-- The shipped HangHorizontalOffset is NEGATIVE, and the sign is easy to get backwards --
			-- getting it wrong buries the character inside the wall it is hanging on.
			expect(ParkourMath.HangPosition(edge, wallNormal, -2.4, -0.85).Z > edge.Z).to.equal(true)
		end)

		it("survives a degenerate (perfectly horizontal) wall normal", function()
			local position = ParkourMath.HangPosition(edge, Vector3.new(0, 1, 0), -2.4, -0.85)
			expectClose(position.X, 0)
			expectClose(position.Z, 0)
			expectClose(position.Y, 7.6)
		end)
	end)

	describe("ParkourMath.EaseOutCubic", function()
		it("pins both endpoints", function()
			expectClose(ParkourMath.EaseOutCubic(0), 0)
			expectClose(ParkourMath.EaseOutCubic(1), 1)
		end)

		it("is past the halfway mark at the halfway point -- it eases OUT, not in", function()
			-- The property the ledge grab actually depends on, and the one that distinguishes this from
			-- TraversalEase (which is exactly 0.5 at t=0.5). If this ever drops to or below 0.5 the curve
			-- has been turned back into a smoothstep and the grab regains the hesitation it was written to
			-- remove.
			expect(ParkourMath.EaseOutCubic(0.5) > 0.5).to.equal(true)
			expectClose(ParkourMath.EaseOutCubic(0.5), 0.875)
		end)

		it("clamps rather than extrapolating outside [0, 1]", function()
			-- A frame-time spike drives alpha past 1 routinely; extrapolating there would overshoot the
			-- hang pose and snap back.
			expectClose(ParkourMath.EaseOutCubic(-5), 0)
			expectClose(ParkourMath.EaseOutCubic(5), 1)
		end)

		it("never decreases across its domain", function()
			local previous = -1
			for step = 0, 20 do
				local value = ParkourMath.EaseOutCubic(step / 20)
				expect(value >= previous).to.equal(true)
				previous = value
			end
		end)
	end)

	describe("ParkourMath.DownhillDirection", function()
		it("points the way the normal leans, not the opposite way", function()
			local fallLine = ParkourMath.DownhillDirection(Vector3.new(0.5, 1, 0).Unit)
			expect(fallLine.X > 0).to.equal(true)
			expectClose(fallLine.Magnitude, 1)
			expectClose(fallLine.Y, 0)
		end)

		it("has no fall line on flat ground", function()
			expect(ParkourMath.DownhillDirection(Vector3.new(0, 1, 0))).to.equal(Vector3.zero)
		end)

		it("agrees with SignedSlopeAlong -- travelling along it is maximally downhill", function()
			-- The two must not be able to disagree: SignedSlopeAlong is defined in terms of this, and a
			-- future caller that re-derived the fall line by hand is exactly how the original sign error
			-- would come back.
			local normal = Vector3.new(-0.3, 1, 0.7).Unit
			local fallLine = ParkourMath.DownhillDirection(normal)
			expectClose(ParkourMath.SignedSlopeAlong(normal, fallLine), ParkourMath.SlopeAngle(normal))
		end)
	end)

	describe("ParkourMath.SignedSlopeAlong", function()
		-- A surface whose normal leans toward +X falls away toward +X, THE SAME WAY. This block
		-- previously asserted the opposite, which is why it passed against a sign error that inverted
		-- every slope decision in the feature. Derivation, so the premise is checkable rather than
		-- asserted: points on this plane satisfy rampNormal:Dot(p) == 0, so at x = 1 the surface sits at
		-- y = -0.5 and at x = -1 it sits at y = 0.5 -- height falls as x rises. The direction-free tests
		-- below (across, flat, degenerate) could not catch this on their own; only these two can, which
		-- is the whole reason they name a direction.
		local rampNormal = Vector3.new(0.5, 1, 0).Unit

		it("is positive travelling downhill", function()
			expect(ParkourMath.SignedSlopeAlong(rampNormal, Vector3.new(1, 0, 0)) > 0).to.equal(true)
		end)

		it("is negative travelling uphill", function()
			expect(ParkourMath.SignedSlopeAlong(rampNormal, Vector3.new(-1, 0, 0)) < 0).to.equal(true)
		end)

		it("agrees with the direction gravity actually pulls along the surface", function()
			-- The independent check: project gravity onto the plane and confirm the signed slope is
			-- positive along it. Derived from the normal rather than hardcoded, so this stays a real
			-- second opinion if rampNormal is ever changed -- a test that merely restated the two above
			-- would have passed against the original bug too.
			local gravity = Vector3.new(0, -196.2, 0)
			local alongSurface = gravity - rampNormal * gravity:Dot(rampNormal)
			expect(ParkourMath.SignedSlopeAlong(rampNormal, alongSurface) > 0).to.equal(true)
		end)

		it("is zero travelling across the slope", function()
			expectClose(ParkourMath.SignedSlopeAlong(rampNormal, Vector3.new(0, 0, 1)), 0)
		end)

		it("is zero on flat ground regardless of direction", function()
			expectClose(ParkourMath.SignedSlopeAlong(Vector3.new(0, 1, 0), Vector3.new(1, 0, 1)), 0)
		end)

		it("is zero for a degenerate travel direction rather than erroring", function()
			expect(ParkourMath.SignedSlopeAlong(rampNormal, Vector3.zero)).to.equal(0)
		end)
	end)

	describe("ParkourMath.IntegrateSlideSpeed", function()
		-- Shared arguments, so each test below reads as the one variable it is actually about.
		-- Roblox's own default gravity, since the shipped tuning is calibrated against it.
		local FRICTION = 17
		local GRAVITY_FRACTION = 0.7
		local UPHILL_SCALE = 2.2
		local GRAVITY = 196.2
		local MAX_SPEED = 80

		local function integrate(speed: number, slope: number, surfaceScale: number?, dt: number?): number
			return ParkourMath.IntegrateSlideSpeed(
				speed,
				slope,
				FRICTION,
				GRAVITY_FRACTION,
				UPHILL_SCALE,
				surfaceScale or 1,
				GRAVITY,
				MAX_SPEED,
				dt or 0.1
			)
		end

		it("bleeds speed on flat ground at exactly the flat friction rate", function()
			-- The load-bearing compatibility check for the move to a physical model: at zero slope cos is
			-- 1 and sin is 0, so this must reduce to the previously-tuned flat behavior EXACTLY. A change
			-- here means the flat slide feel silently moved.
			expectClose(integrate(34, 0), 32.3)
		end)

		it("gains speed downhill", function()
			expect(integrate(30, 20) > 30).to.equal(true)
		end)

		it("accelerates far harder on a steep slope than a gentle one", function()
			-- The actual defect this model replaced: a linear per-degree term made 45 degrees feel barely
			-- different from 20. Real slope pull grows as sin, so the gap has to be large.
			local gentleGain = integrate(30, 15) - 30
			local steepGain = integrate(30, 45) - 30
			expect(steepGain > gentleGain * 2.5).to.equal(true)
		end)

		it("loses less to friction as the slope steepens", function()
			-- Friction scales with the normal force, so it falls away on a steep face. This is half of why
			-- a real steep descent runs away from you, and it is the half a constant-friction model misses
			-- entirely.
			local flatFriction = 30 - integrate(30, 0)
			local steepTotal = integrate(30, 60) - 30
			local steepPull = GRAVITY * math.sin(math.rad(60)) * GRAVITY_FRACTION * 0.1
			local steepFriction = steepPull - steepTotal
			expect(steepFriction < flatFriction).to.equal(true)
		end)

		it("reaches a genuinely high speed down a steep slope within a second", function()
			-- The player-facing symptom, asserted directly: a steep descent must actually get fast rather
			-- than settling at a mildly-above-sprint constant.
			local speed = 34
			for _ = 1, 60 do
				speed = integrate(speed, 45, 1, 1 / 60)
			end
			expect(speed > 70).to.equal(true)
		end)

		it("dies quickly uphill, where the slope term is scaled up", function()
			expect(integrate(30, -20) < integrate(30, 0)).to.equal(true)
		end)

		it("honors a surface's own friction multiplier", function()
			expect(integrate(34, 0, 0.2) > integrate(34, 0, 1)).to.equal(true)
		end)

		it("clamps to the maximum no matter how steep the downhill", function()
			expect(integrate(45, 80, 1, 1)).to.equal(MAX_SPEED)
		end)

		it("never returns a negative speed", function()
			expect(integrate(1, -80, 1, 1)).to.equal(0)
		end)

		it("never turns friction into acceleration past vertical", function()
			-- Absolute cosine: a slope steeper than 90 degrees would otherwise produce a negative friction
			-- term, which reads as the surface pushing the player along.
			local past = integrate(30, 100, 1, 0.1)
			expect(past == past).to.equal(true)
			expect(past <= MAX_SPEED).to.equal(true)
		end)
	end)

	describe("ParkourMath.WallTangent", function()
		local wallNormal = Vector3.new(1, 0, 0)

		it("returns a horizontal unit vector along the wall", function()
			local tangent = ParkourMath.WallTangent(wallNormal, Vector3.new(0, 0, 1))
			expectClose(tangent.Magnitude, 1)
			expectClose(tangent.Y, 0)
			expectClose(tangent:Dot(wallNormal), 0)
		end)

		it("orients to agree with the direction of travel", function()
			local forward = ParkourMath.WallTangent(wallNormal, Vector3.new(0, 0, 1))
			local backward = ParkourMath.WallTangent(wallNormal, Vector3.new(0, 0, -1))
			expect(forward:Dot(backward) < 0).to.equal(true)
		end)

		it("returns zero for a horizontal surface, which has no usable tangent", function()
			expect(ParkourMath.WallTangent(Vector3.new(0, 1, 0), Vector3.new(0, 0, 1))).to.equal(Vector3.zero)
		end)

		it("returns zero when there is no travel direction to agree with", function()
			expect(ParkourMath.WallTangent(wallNormal, Vector3.zero)).to.equal(Vector3.zero)
		end)
	end)

	describe("ParkourMath.ApproachAngle", function()
		it("is zero when travelling exactly along the tangent", function()
			expectClose(ParkourMath.ApproachAngle(Vector3.new(0, 0, 1), Vector3.new(0, 0, 1)), 0)
		end)

		it("is ninety degrees when travelling perpendicular to it", function()
			expectClose(ParkourMath.ApproachAngle(Vector3.new(1, 0, 0), Vector3.new(0, 0, 1)), 90)
		end)

		it("returns a maximally-disqualifying 180 for a degenerate tangent", function()
			-- So a caller comparing against a max-angle threshold reads the degenerate case as a refusal
			-- without needing its own nil check.
			expect(ParkourMath.ApproachAngle(Vector3.new(0, 0, 1), Vector3.zero)).to.equal(180)
		end)
	end)

	describe("ParkourMath.WallJumpVelocity", function()
		local wallNormal = Vector3.new(1, 0, 0)

		it("pushes away from the wall along its normal", function()
			local velocity = ParkourMath.WallJumpVelocity(wallNormal, Vector3.zero, 0, 26, 46, 0.55, 0, 0.86)
			expect(velocity.X > 0).to.equal(true)
		end)

		it("adds upward lift", function()
			local velocity = ParkourMath.WallJumpVelocity(wallNormal, Vector3.zero, 0, 26, 46, 0.55, 0, 0.86)
			expectClose(velocity.Y, 46)
		end)

		it("carries a fraction of existing along-wall momentum", function()
			local velocity = ParkourMath.WallJumpVelocity(wallNormal, Vector3.new(0, 0, 1), 20, 26, 46, 0.5, 0, 0.86)
			expectClose(velocity.Z, 10)
		end)

		it("scales push and lift down on each chained jump", function()
			local first = ParkourMath.WallJumpVelocity(wallNormal, Vector3.zero, 0, 26, 46, 0.55, 0, 0.86)
			local third = ParkourMath.WallJumpVelocity(wallNormal, Vector3.zero, 0, 26, 46, 0.55, 2, 0.86)
			expect(third.Y < first.Y).to.equal(true)
			expect(third.X < first.X).to.equal(true)
		end)

		it("leaves the carried momentum unscaled by the chain falloff", function()
			-- Only the push and lift decay; a fast approach still contributes its full share, so a chain
			-- built out of real speed stays worth more than one built out of repeated wall contact.
			local first = ParkourMath.WallJumpVelocity(wallNormal, Vector3.new(0, 0, 1), 20, 26, 46, 0.5, 0, 0.86)
			local third = ParkourMath.WallJumpVelocity(wallNormal, Vector3.new(0, 0, 1), 20, 26, 46, 0.5, 2, 0.86)
			expectClose(first.Z, third.Z)
		end)

		it("survives a degenerate wall normal without producing NaN", function()
			local velocity = ParkourMath.WallJumpVelocity(Vector3.zero, Vector3.zero, 0, 26, 46, 0.55, 0, 0.86)
			expect(velocity.X == velocity.X).to.equal(true)
			expectClose(velocity.Y, 46)
		end)
	end)

	describe("ParkourMath.ClassifyLanding", function()
		it("classifies a short drop as soft", function()
			expect(ParkourMath.ClassifyLanding(3, 9, 22)).to.equal("Soft")
		end)

		it("treats the soft threshold itself as soft", function()
			expect(ParkourMath.ClassifyLanding(9, 9, 22)).to.equal("Soft")
		end)

		it("classifies a mid drop as medium", function()
			expect(ParkourMath.ClassifyLanding(15, 9, 22)).to.equal("Medium")
		end)

		it("treats the medium threshold itself as medium", function()
			expect(ParkourMath.ClassifyLanding(22, 9, 22)).to.equal("Medium")
		end)

		it("classifies anything past the medium threshold as hard", function()
			expect(ParkourMath.ClassifyLanding(22.1, 9, 22)).to.equal("Hard")
		end)
	end)

	describe("ParkourMath.SteerDirection", function()
		it("snaps to the desired direction when it is within the frame's turn budget", function()
			local result = ParkourMath.SteerDirection(Vector3.new(0, 0, 1), Vector3.new(0.05, 0, 1), 360, 1)
			expectClose(result:Dot(Vector3.new(0.05, 0, 1).Unit), 1)
		end)

		it("rotates only partway toward a far-off direction", function()
			local result = ParkourMath.SteerDirection(Vector3.new(0, 0, 1), Vector3.new(1, 0, 0), 90, 0.1)
			-- 9 degrees of a 90 degree turn: still much closer to the original than to the target.
			expect(result:Dot(Vector3.new(0, 0, 1)) > 0.95).to.equal(true)
			expect(result:Dot(Vector3.new(1, 0, 0)) < 0.2).to.equal(true)
		end)

		it("handles an exact reversal without producing NaN", function()
			local result = ParkourMath.SteerDirection(Vector3.new(0, 0, 1), Vector3.new(0, 0, -1), 90, 0.1)
			expect(result.X == result.X).to.equal(true)
			expectClose(result.Magnitude, 1)
		end)

		it("keeps the current direction when there is nothing to steer toward", function()
			local result = ParkourMath.SteerDirection(Vector3.new(0, 0, 1), Vector3.zero, 90, 0.1)
			expectClose(result.Z, 1)
		end)
	end)

	describe("ParkourMath.CoyoteAvailable", function()
		it("allows a jump inside the window", function()
			expect(ParkourMath.CoyoteAvailable(100.05, 100, 0.12, true)).to.equal(true)
		end)

		it("allows a jump exactly at the window boundary", function()
			-- Uses 0.125 rather than the shipped 0.12, deliberately: 0.125 is exactly representable in
			-- binary, so `1.125 - 1` is exactly 0.125 and this genuinely tests the inclusive `<=` the
			-- implementation uses. With 0.12, `100.12 - 100` is 0.12000000000000455 -- a hair PAST the
			-- boundary -- so the same test would be asserting a floating-point accident rather than the
			-- behavior.
			expect(ParkourMath.CoyoteAvailable(1.125, 1, 0.125, true)).to.equal(true)
		end)

		it("refuses past the window", function()
			expect(ParkourMath.CoyoteAvailable(100.13, 100, 0.12, true)).to.equal(false)
		end)

		it("refuses when the player has the assist switched off", function()
			expect(ParkourMath.CoyoteAvailable(100.05, 100, 0.12, false)).to.equal(false)
		end)

		it("refuses when the character has never left the ground", function()
			expect(ParkourMath.CoyoteAvailable(100, 0, 0.12, true)).to.equal(false)
		end)
	end)

	describe("ParkourMath.BufferLive", function()
		it("honors a press inside the window", function()
			expect(ParkourMath.BufferLive(100.1, 100, 0.15, true)).to.equal(true)
		end)

		it("drops a press past the window", function()
			expect(ParkourMath.BufferLive(100.2, 100, 0.15, true)).to.equal(false)
		end)

		it("treats a never-pressed timestamp as not live regardless of window", function()
			expect(ParkourMath.BufferLive(100, 0, 999, true)).to.equal(false)
		end)

		it("refuses when the player has the assist switched off", function()
			expect(ParkourMath.BufferLive(100.1, 100, 0.15, false)).to.equal(false)
		end)
	end)

	describe("ParkourMath.PlaybackSpeed", function()
		it("returns 1 at the reference speed", function()
			expectClose(ParkourMath.PlaybackSpeed(27, 27, 0.6, 1.6), 1)
		end)

		it("clamps to the minimum well below the reference", function()
			expect(ParkourMath.PlaybackSpeed(1, 27, 0.6, 1.6)).to.equal(0.6)
		end)

		it("clamps to the maximum well above it", function()
			expect(ParkourMath.PlaybackSpeed(200, 27, 0.6, 1.6)).to.equal(1.6)
		end)

		it("returns 1 for a zero reference rather than dividing by zero", function()
			expect(ParkourMath.PlaybackSpeed(20, 0, 0.6, 1.6)).to.equal(1)
		end)
	end)

	describe("ParkourMath.StepInterval", function()
		it("returns the authored interval at the reference speed", function()
			expectClose(ParkourMath.StepInterval(27, 27, 0.33, 0.15, 0.6), 0.33)
		end)

		it("shortens the gap as the character speeds up -- the inverse of PlaybackSpeed's ratio", function()
			expectClose(ParkourMath.StepInterval(54, 27, 0.33, 0.05, 0.6), 0.165)
		end)

		it("lengthens the gap as the character slows down", function()
			expectClose(ParkourMath.StepInterval(13.5, 27, 0.2, 0.05, 0.6), 0.4)
		end)

		it("clamps at both ends", function()
			expect(ParkourMath.StepInterval(500, 27, 0.33, 0.15, 0.6)).to.equal(0.15)
			expect(ParkourMath.StepInterval(0.5, 27, 0.33, 0.15, 0.6)).to.equal(0.6)
		end)

		it("returns the ceiling for a stopped character or a zero reference, never a division by zero", function()
			expect(ParkourMath.StepInterval(0, 27, 0.33, 0.15, 0.6)).to.equal(0.6)
			expect(ParkourMath.StepInterval(27, 0, 0.33, 0.15, 0.6)).to.equal(0.6)
		end)
	end)

	describe("ParkourMath.ExitMomentum", function()
		it("retains the given fraction of entry momentum", function()
			expectClose(ParkourMath.ExitMomentum(30, 0.5, 0), 15)
		end)

		it("floors at the minimum so a traversal never ends in a dead stop", function()
			expect(ParkourMath.ExitMomentum(5, 0.1, 10)).to.equal(10)
		end)

		it("allows a fraction above 1 -- the slide-jump pays more than the sum of its parts", function()
			expectClose(ParkourMath.ExitMomentum(30, 1.08, 0), 32.4)
		end)
	end)

	describe("ParkourMath.TraversalPoint / TraversalEase", function()
		local start = Vector3.new(0, 0, 0)
		local control = Vector3.new(1, 4, 0)
		local finish = Vector3.new(2, 0, 0)

		it("starts exactly at the start point", function()
			expect(ParkourMath.TraversalPoint(start, control, finish, 0)).to.equal(start)
		end)

		it("ends exactly at the end point -- what makes a vault land where it claimed", function()
			expect(ParkourMath.TraversalPoint(start, control, finish, 1)).to.equal(finish)
		end)

		it("arcs above the straight line between the endpoints", function()
			expect(ParkourMath.TraversalPoint(start, control, finish, 0.5).Y > 0).to.equal(true)
		end)

		it("clamps an out-of-range alpha to the endpoints", function()
			expect(ParkourMath.TraversalPoint(start, control, finish, 5)).to.equal(finish)
			expect(ParkourMath.TraversalPoint(start, control, finish, -5)).to.equal(start)
		end)

		it("eases from 0 to 1 with a flat start and finish", function()
			expect(ParkourMath.TraversalEase(0)).to.equal(0)
			expect(ParkourMath.TraversalEase(1)).to.equal(1)
			expectClose(ParkourMath.TraversalEase(0.5), 0.5)
		end)
	end)

	describe("ParkourMath.PrimaryReachDirection", function()
		-- The direction EnvironmentProbe.probeLedge searches along for an automatic ledge grab. Its
		-- whole reason to exist is refusing the LAST fallback every other direction helper in this
		-- framework takes (facing/LookVector) -- see its own header for why an automatic, no-button
		-- probe is the one place that step stops being reasonable.
		it("prefers genuine measured movement over held input", function()
			local result = ParkourMath.PrimaryReachDirection(Vector3.new(0, 0, -1), Vector3.new(1, 0, 0))
			expectClose(result.Z, -1)
			expectClose(result.X, 0)
		end)

		it("falls back to held input when there is no measured movement", function()
			local result = ParkourMath.PrimaryReachDirection(Vector3.zero, Vector3.new(1, 0, 0))
			expectClose(result.X, 1)
		end)

		it("returns the zero vector rather than facing when NEITHER is present", function()
			-- The property this function exists for: a free-falling character with zero horizontal
			-- velocity and no held input gets nothing to search along, even though the character is
			-- still facing SOME direction. Without this, a passive fall next to a wall the camera
			-- happens to point at reads as a reach for it.
			expect(ParkourMath.PrimaryReachDirection(Vector3.zero, Vector3.zero)).to.equal(Vector3.zero)
		end)

		it("flattens both inputs -- this is a planar question", function()
			local result = ParkourMath.PrimaryReachDirection(Vector3.new(0, -50, -1), Vector3.zero)
			expect(result.Y).to.equal(0)
			expectClose(result.Magnitude, 1)
		end)

		it("never returns a NaN vector for a near-zero measured direction", function()
			local result = ParkourMath.PrimaryReachDirection(Vector3.new(1e-9, 0, 0), Vector3.new(0, 0, -1))
			expect(result.X == result.X).to.equal(true)
			expectClose(result.Z, -1)
		end)
	end)

	describe("ParkourMath.SolveLaunchVelocity", function()
		-- The assisted wall-jump's trajectory. Asserted by SIMULATING the arc rather than by comparing
		-- against a hand-computed velocity: the property that matters to a player is "does this land on
		-- the thing it was aimed at," and a test written against the closed-form answer would pass just as
		-- happily if the closed form itself were wrong. Roblox's own default gravity, so the numbers here
		-- are the numbers the game actually flies.
		local GRAVITY = 196.2

		-- Flies the velocity forward in small steps and returns the closest the arc ever passes to the
		-- target. Fixed step rather than solving for the arrival time, so this stays an independent check
		-- of the solver rather than a second copy of it.
		local function closestApproach(start: Vector3, velocity: Vector3, target: Vector3): number
			local best = math.huge
			local step = 1 / 240
			local elapsed = 0
			while elapsed <= 4 do
				local position = start + velocity * elapsed - Vector3.new(0, 0.5 * GRAVITY * elapsed * elapsed, 0)
				best = math.min(best, (position - target).Magnitude)
				elapsed += step
			end
			return best
		end

		local function solve(start: Vector3, target: Vector3): (Vector3, boolean)
			return ParkourMath.SolveLaunchVelocity(start, target, GRAVITY, 1.8, 1.09, 34, 62, 72)
		end

		-- Tolerance on "passes through the target," and it is PROPORTIONAL rather than flat for a reason
		-- that is the feature itself: the solve deliberately overshoots by ReachMargin, which is a
		-- fraction of the horizontal speed, so a longer flight overshoots by more studs than a short one
		-- does. Asserting a flat stud budget would be asserting that the surplus shrinks with distance,
		-- which is the opposite of what "a little more than enough to reach" means. The constant term is
		-- just slack for the fixed-step integration below.
		local function arrivalTolerance(start: Vector3, target: Vector3): number
			return ParkourMath.PlanarSpeed(target - start) * 0.15 + 0.5
		end

		it("flies an arc that passes through a target level with the launch", function()
			local start = Vector3.new(0, 20, 0)
			local target = Vector3.new(18, 20, 0)
			local velocity, reachable = solve(start, target)
			expect(reachable).to.equal(true)
			expect(closestApproach(start, velocity, target) < arrivalTolerance(start, target)).to.equal(true)
		end)

		it("flies an arc that reaches a target ABOVE the launch", function()
			-- The ascending chain -- a wall-jump up to a higher ledge -- and the case a fixed push is
			-- worst at, since the player has to estimate both how hard and how high.
			local start = Vector3.new(0, 20, 0)
			local target = Vector3.new(14, 26, 0)
			local velocity, reachable = solve(start, target)
			expect(reachable).to.equal(true)
			expect(closestApproach(start, velocity, target) < arrivalTolerance(start, target)).to.equal(true)
		end)

		it("flies an arc that reaches a target BELOW the launch", function()
			local start = Vector3.new(0, 30, 0)
			local target = Vector3.new(22, 19, 0)
			local velocity, reachable = solve(start, target)
			expect(reachable).to.equal(true)
			expect(closestApproach(start, velocity, target) < arrivalTolerance(start, target)).to.equal(true)
		end)

		it("arrives DESCENDING, not still rising", function()
			-- The states downstream depend on it: States/LedgeHanging refuses a grab from a character
			-- rising faster than Ledge.MaxVerticalSpeedToGrab, so a rising arrival would deliver the assist
			-- to a state that then declines to catch it. Checked at the moment the arc first reaches the
			-- target's height on its way back down.
			local start = Vector3.new(0, 20, 0)
			local target = Vector3.new(16, 24, 0)
			local velocity = solve(start, target)
			local arrivalTime = (velocity.Y + math.sqrt(velocity.Y * velocity.Y - 2 * GRAVITY * 4)) / GRAVITY
			local verticalAtArrival = velocity.Y - GRAVITY * arrivalTime
			expect(verticalAtArrival < 0).to.equal(true)
		end)

		it("clears the target's height by the requested apex margin on the way", function()
			-- Not the same assertion as "reaches it": an arc that arrives exactly AT the lip's height
			-- arrives through the front face of whatever the lip belongs to. The clearance is what makes
			-- the arrival a landing rather than a collision.
			local start = Vector3.new(0, 20, 0)
			local target = Vector3.new(12, 26, 0)
			local velocity = solve(start, target)
			local apex = start.Y + (velocity.Y * velocity.Y) / (2 * GRAVITY)
			expect(apex >= target.Y + 1.7).to.equal(true)
		end)

		it("gives MORE than the minimum, but not much more", function()
			-- The design constraint in one test: enough surplus that a frame of error is not a miss, little
			-- enough that the arc still reads as a jump. Measured as the overshoot past the target at the
			-- moment the arc returns to the target's height.
			local start = Vector3.new(0, 20, 0)
			local target = Vector3.new(20, 20, 0)
			local velocity = solve(start, target)
			local flightTime = (2 * velocity.Y) / GRAVITY
			local travelled = ParkourMath.PlanarSpeed(velocity) * flightTime
			expect(travelled > 20).to.equal(true)
			expect(travelled < 20 * 1.2).to.equal(true)
		end)

		it("reports a target past the vertical cap as unreachable rather than pretending", function()
			-- What stops a well-placed pair of walls from being an elevator. The caller refuses the assist
			-- entirely on a false here (States/WallJumping.Enter) and flies the ordinary push instead.
			local start = Vector3.new(0, 20, 0)
			local _velocity, reachable = solve(start, Vector3.new(6, 60, 0))
			expect(reachable).to.equal(false)
		end)

		it("reports a target past the horizontal cap as unreachable", function()
			local start = Vector3.new(0, 20, 0)
			local _velocity, reachable = solve(start, Vector3.new(300, 20, 0))
			expect(reachable).to.equal(false)
		end)

		it("never returns a NaN velocity for a degenerate target", function()
			local start = Vector3.new(0, 20, 0)
			local velocity = solve(start, start)
			expect(velocity.X == velocity.X).to.equal(true)
			expect(velocity.Y == velocity.Y).to.equal(true)
			expect(velocity.Z == velocity.Z).to.equal(true)
		end)
	end)

	describe("ParkourMath.CorridorKickHeight", function()
		-- The chimney climb's height budget. The property that matters is not any particular number but
		-- that a kick GAINS height at all -- a corridor jump that aims level is the failure this function
		-- was written to fix, and it is invisible in a screenshot and obvious in play.
		local GRAVITY = 196.2
		local UP_SPEED = 68
		local APEX_GAIN = (UP_SPEED * UP_SPEED) / (2 * GRAVITY)

		local function height(gap: number, maxPlanar: number?): number
			return ParkourMath.CorridorKickHeight(gap, GRAVITY, UP_SPEED, maxPlanar or 72, 1.09)
		end

		it("gains the full apex height across an ordinary corridor", function()
			-- A gap a player would actually build: the horizontal cap is nowhere near binding, so the whole
			-- of the lift is available as climb.
			expectClose(height(10), APEX_GAIN)
			expect(APEX_GAIN > 11).to.equal(true)
		end)

		it("gains real height even across a narrow shaft", function()
			expectClose(height(3), APEX_GAIN)
		end)

		it("aims LOWER across a gap too wide to cross at apex", function()
			-- The inverse relationship that is easy to get backwards: arriving at apex is the SHORTEST
			-- flight, so a wide gap needs a longer one, which means aiming below the apex and arriving on
			-- the way down. Less climb per kick, but a kick that still happens.
			local wide = height(24)
			expect(wide < APEX_GAIN).to.equal(true)
			expect(wide > 0).to.equal(true)
		end)

		it("falls monotonically as the gap widens past the affordable point", function()
			local previous = math.huge
			for gap = 20, 34, 2 do
				local current = height(gap)
				expect(current <= previous).to.equal(true)
				previous = current
			end
		end)

		it("reports no climb at all for a gap past what the horizontal cap can cross", function()
			expectClose(height(60, 20), 0)
		end)

		it("never returns a negative height or a NaN", function()
			local degenerate = height(0)
			expect(degenerate == degenerate).to.equal(true)
			expect(degenerate >= 0).to.equal(true)
			expect(height(-5) >= 0).to.equal(true)
		end)

		it("is reachable by the solver it feeds -- the two must agree", function()
			-- The integration that actually matters: States/WallJumping hands this height to
			-- SolveLaunchVelocity with the up-speed pinned at both ends, and a height the solver then calls
			-- unreachable would silently drop the assist on exactly the jump it was written for. A small
			-- safety shave (Assist.CorridorHeightSafetyStuds) exists for the apex case, where the two agree
			-- to the last decimal place; this asserts the shave is enough.
			for gap = 4, 26, 2 do
				local climb = math.max(height(gap) - 0.15, 0)
				local start = Vector3.new(0, 20, 0)
				local target = Vector3.new(gap, 20 + climb, 0)
				local _velocity, reachable =
					ParkourMath.SolveLaunchVelocity(start, target, GRAVITY, 0, 1.09, UP_SPEED, UP_SPEED, 72)
				expect(reachable).to.equal(true)
			end
		end)
	end)

	describe("ParkourMath.WallJumpCandidateScore", function()
		local FROM = Vector3.new(0, 20, 0)
		local AIM = Vector3.new(0, 0, -1)

		local function score(position: Vector3, normal: Vector3): number
			return ParkourMath.WallJumpCandidateScore(FROM, AIM, position, normal, 6, 42, 1, 0.45, 0.55, 0.12, 0.3)
		end

		it("scores a square surface straight ahead above an angled one beside it", function()
			local ahead = score(Vector3.new(0, 20, -20), Vector3.new(0, 0, 1))
			local beside = score(Vector3.new(18, 20, -10), Vector3.new(-0.8, 0, 0.6).Unit)
			expect(ahead > beside).to.equal(true)
		end)

		it("prefers the nearer of two equally-aimed surfaces", function()
			local near = score(Vector3.new(0, 20, -12), Vector3.new(0, 0, 1))
			local far = score(Vector3.new(0, 20, -34), Vector3.new(0, 0, 1))
			expect(near > far).to.equal(true)
		end)

		it("refuses anything behind the aim direction", function()
			expect(score(Vector3.new(0, 20, 20), Vector3.new(0, 0, -1))).to.equal(0)
		end)

		it("refuses a surface whose face is turned away -- a graze, not a landing", function()
			-- Geometrically ahead and well inside the distance band, but its normal points along the
			-- flight rather than back at it: arriving there is a scrape past, not an attach.
			expect(score(Vector3.new(0, 20, -20), Vector3.new(0, 0, -1))).to.equal(0)
		end)

		it("refuses anything nearer than the minimum or past the scan distance", function()
			expect(score(Vector3.new(0, 20, -3), Vector3.new(0, 0, 1))).to.equal(0)
			expect(score(Vector3.new(0, 20, -80), Vector3.new(0, 0, 1))).to.equal(0)
		end)

		it("returns zero rather than NaN for a degenerate normal", function()
			expect(score(Vector3.new(0, 20, -20), Vector3.zero)).to.equal(0)
		end)
	end)
end
