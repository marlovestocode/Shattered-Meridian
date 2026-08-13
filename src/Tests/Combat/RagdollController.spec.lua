--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Shared.Constants)
local RagdollController = require(ServerScriptService.Server.Combat.RagdollController)

-- Builds a minimal R15-shaped rig -- just enough for RagdollController to find a HumanoidRootPart
-- and a Humanoid; HoldAloft/ClearHold/Recover under test here never touch limbs, so no other parts
-- or Motor6Ds are needed. Deliberately NOT anchored -- HoldAloft (RagdollController.lua's own guard,
-- "if rootPart.Anchored then return") is a genuine no-op on an anchored part, which would silently
-- skip the exact pin-creation this spec is testing. Every SetNetworkOwner/velocity write RagdollController
-- makes on an unanchored, unparented-to-Workspace part is already pcall-guarded (this module's own
-- header: "every ownership/physics call is pcall-guarded"), so a failed ownership call here is
-- expected and harmless -- only the Instance bookkeeping (AirComboHoldAlign et al.) is under test.
local function makeRig(): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.Parent = model
	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Parent = model
	return model, humanoid, rootPart
end

-- Runs a slam on a rig sitting exactly `dropStuds` above the top surface of a real floor in Workspace,
-- and reports the downward speed (studs/s, positive) that actually landed on the root. Both the rig and
-- the floor must be genuinely parented into Workspace: RagdollController.resolveGroundClearance answers
-- via Workspace:Raycast, so an unparented rig (what every other test here uses) finds no floor at all
-- and is the UNCLAMPED case by construction -- which is exactly why the pre-existing slam tests above
-- kept passing at full velocity and never covered the grounded bug this block exists for.
--
-- The root is given an explicit 2-stud height and the bare Humanoid reports HipHeight = 0, so
-- resolveSlamScale's `restingRootHeight` (Size.Y * 0.5 + HipHeight) is exactly 1 here -- i.e. dropStuds
-- of 1 IS "standing on the floor," and usable drop is dropStuds - 1.
local function slamDownSpeedWithFloorBelow(dropStuds: number): (number, Vector3, boolean)
	local model, humanoid, rootPart = makeRig()
	rootPart.Size = Vector3.new(2, 2, 1)
	rootPart.CFrame = CFrame.new(0, 500, 0)
	model.Parent = Workspace

	local floor = Instance.new("Part")
	floor.Name = "SlamClampTestFloor"
	floor.Anchored = true
	floor.Size = Vector3.new(64, 1, 64)
	-- Top face exactly `dropStuds` beneath the root's CENTER (the raycast origin).
	floor.CFrame = CFrame.new(0, 500 - dropStuds - 0.5, 0)
	floor.Parent = Workspace

	local immediateGroundImpact = RagdollController.SlamToGround(model, humanoid, rootPart, nil, nil, {
		DownVelocity = 140,
		FaceDownSpin = 9,
		KnockdownSeconds = 1.25,
	})
	local downSpeed = -rootPart.AssemblyLinearVelocity.Y
	local angular = rootPart.AssemblyAngularVelocity

	RagdollController.Recover(model)
	model:Destroy()
	floor:Destroy()
	return downSpeed, angular, immediateGroundImpact
end

-- A rig with real Motor6Ds, for the joint-swap / recovery-blend tests. Mirrors the shape
-- buildRagdollJoints actually branches on: one joint that TOUCHES the HumanoidRootPart (must stay
-- rigid, so the body keeps a single stable primary assembly) and one that doesn't (must become a
-- BallSocketConstraint). Parented into Workspace because RagdollController.Update abandons any
-- ragdoll whose character has been unparented, which would skip the lifecycle under test entirely.
local function makeJointedRig(): (Model, Humanoid, BasePart, Motor6D, Motor6D)
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.Parent = model

	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "UpperTorso"
	torso.Parent = model

	local arm = Instance.new("Part")
	arm.Name = "LeftUpperArm"
	arm.Parent = model

	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "Root"
	rootJoint.Part0 = rootPart
	rootJoint.Part1 = torso
	rootJoint.Parent = rootPart

	local shoulder = Instance.new("Motor6D")
	shoulder.Name = "LeftShoulder"
	shoulder.Part0 = torso
	shoulder.Part1 = arm
	shoulder.Parent = torso

	model.Parent = Workspace
	return model, humanoid, rootPart, rootJoint, shoulder
end

local function holdInstanceNames(rootPart: BasePart): { string }
	local names = {}
	for _, name in ipairs({
		"AirComboHoldAlign",
		"AirComboHoldAttachment",
		"AirComboHoldGravityCancel",
		"AirComboHoldOrient",
	}) do
		if rootPart:FindFirstChild(name) then
			table.insert(names, name)
		end
	end
	return names
end

return function()
	describe("RagdollController.HoldAloft / ClearHold", function()
		it("creates a rigid AlignPosition pin on the held rootPart", function()
			local _model, _humanoid, rootPart = makeRig()

			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
			})

			local align = rootPart:FindFirstChild("AirComboHoldAlign")
			expect(align).to.be.ok()
			expect((align :: AlignPosition).MaxForce).to.equal(math.huge)
		end)

		it("removes the pin and is idempotent when called again with nothing held", function()
			local _model, _humanoid, rootPart = makeRig()

			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
			})
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.be.ok()

			RagdollController.ClearHold(rootPart, nil)
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.equal(nil)

			-- Calling again with no active hold must not error -- this is exactly the safety property
			-- CombatSystem.ResetCombatState's new unconditional third cleanup path depends on: it now
			-- calls ClearHold on every reset target's own rootPart regardless of whether that player
			-- happens to be currently held.
			RagdollController.ClearHold(rootPart, nil)
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.equal(nil)
		end)

		it(
			"Recover (ragdoll-only reversal) does NOT clear a HoldAloft pin on the same rootPart -- "
				.. "only ClearHold does, which is the exact gap ResetCombatState's third cleanup path closes",
			function()
				local model, humanoid, rootPart = makeRig()

				-- Mirrors what happens to an air-combo TARGET: LaunchAndRagdoll ragdolls the body, then
				-- AirCombo.Apply calls HoldAloft on the SAME rootPart to pin it aloft. Both writes land
				-- on the target's rootPart, but (per the bug this fix addresses) the CombatState field
				-- that would normally gate a ClearHold call is only ever set on the ATTACKER's own
				-- CombatState, never the target's.
				RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
					UpVelocity = 10,
					HorizontalVelocity = 5,
					BackwardSpin = 0,
					RagdollSeconds = 1.8,
				})
				RagdollController.HoldAloft(rootPart, nil, {
					Position = Vector3.new(0, 12, 0),
					DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
					MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
					Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
				})
				expect(#holdInstanceNames(rootPart) > 0).to.equal(true)

				RagdollController.Recover(model)

				-- The bug: Recover reverses the ragdoll joints/ownership but leaves the AlignPosition
				-- pin fully intact and still applying MaxForce = math.huge to this rootPart.
				expect(#holdInstanceNames(rootPart) > 0).to.equal(true)

				-- The fix: an unconditional ClearHold alongside Recover actually releases the pin.
				RagdollController.ClearHold(rootPart, nil)
				expect(#holdInstanceNames(rootPart)).to.equal(0)
			end
		)

		-- Regression coverage for "HoldAloft doesn't report whether the pin it was asked to build
		-- actually exists." AirCombo.lua's own held-lockout writes (setHeldExpiry/airComboChaseExpiry
		-- -- see AirCombo.spec.lua) depend on this return value to avoid freezing a player at
		-- WalkSpeed 0/RootControlLocked when no physical constraint was ever created for them.
		it("reports true once the pin actually exists, and false for an anchored rootPart", function()
			local model, _humanoid, rootPart = makeRig()

			local held = RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
			})
			expect(held).to.equal(true)
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.be.ok()

			RagdollController.ClearHold(rootPart, nil)
			model:Destroy()

			local model2, _humanoid2, anchoredRoot = makeRig()
			anchoredRoot.Anchored = true
			local heldAnchored = RagdollController.HoldAloft(anchoredRoot, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
			})
			expect(heldAnchored).to.equal(false)
			expect(#holdInstanceNames(anchoredRoot)).to.equal(0)
			model2:Destroy()
		end)

		-- Regression coverage for "Downslam/finisher physics fights an existing AirCombo pin." Every
		-- knockback (LaunchAndRagdoll here; SlamToGround/Ragdoll go through the same applyKnockback
		-- door) must clear a pre-existing hold on the SAME rootPart before entering the ragdoll,
		-- rather than leaving a MaxForce = math.huge AlignPosition pulling the body back toward its
		-- pin point while the launch is also trying to move it.
		it("clears a pre-existing hold before a knockback enters the ragdoll", function()
			local model, humanoid, rootPart = makeRig()

			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
			})
			expect(RagdollController.IsHeld(model)).to.equal(true)

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 10,
				HorizontalVelocity = 5,
				BackwardSpin = 0,
				RagdollSeconds = 1.8,
			})

			expect(RagdollController.IsHeld(model)).to.equal(false)
			expect(#holdInstanceNames(rootPart)).to.equal(0)
			expect(RagdollController.IsRagdolled(model)).to.equal(true)

			RagdollController.Recover(model)
			model:Destroy()
		end)
	end)

	describe("RagdollController.SlamToGround", function()
		it("applies the same downward velocity uniformly to every BasePart", function()
			local model, humanoid, rootPart = makeRig()
			local limb = Instance.new("Part")
			limb.Name = "Limb"
			limb.Parent = model

			local immediateGroundImpact = RagdollController.SlamToGround(model, humanoid, rootPart, nil, nil, {
				DownVelocity = 140,
				FaceDownSpin = 9,
				KnockdownSeconds = 1.25,
			})

			expect(rootPart.AssemblyLinearVelocity).to.equal(Vector3.new(0, -140, 0))
			expect(limb.AssemblyLinearVelocity).to.equal(Vector3.new(0, -140, 0))
			-- This rig is deliberately unparented (makeRig's own header) -- resolveGroundClearance's
			-- raycast finds no floor at all, the opposite extreme from an immediate impact: a genuine
			-- fall with unbounded hangtime ahead of it, same as slamming a target off a cliff/over a void.
			expect(immediateGroundImpact).to.equal(false)
		end)

		it(
			"biases rootPart's angular velocity toward a face-down pitch, away from the attacker, "
				.. "at exactly faceDownSpin magnitude",
			function()
				local model, humanoid, rootPart = makeRig()
				rootPart.Position = Vector3.new(0, 0, 0)
				local attackerRootPart = Instance.new("Part")
				-- Attacker stands at +Z (in front of the target) -- the target should pitch face-down
				-- AWAY from them, i.e. toward -Z, which (see RagdollController.SlamToGround's own
				-- header on the negated spinAxis) resolves to a -X angular velocity here.
				attackerRootPart.Position = Vector3.new(0, 0, 5)

				local faceDownSpin = 9
				RagdollController.SlamToGround(model, humanoid, rootPart, nil, attackerRootPart, {
					DownVelocity = 140,
					FaceDownSpin = faceDownSpin,
					KnockdownSeconds = 1.25,
				})

				local angular = rootPart.AssemblyAngularVelocity
				expect(math.abs(angular.Magnitude - faceDownSpin) < 1e-4).to.equal(true)
				expect(angular.X < 0).to.equal(true)
				expect(math.abs(angular.Y) < 1e-4).to.equal(true)
				expect(math.abs(angular.Z) < 1e-4).to.equal(true)
			end
		)

		-- Regression coverage for "the downslam launches the target INTO THE AIR." AirSlam only requires
		-- the ATTACKER to be airborne, so the ordinary downslam victim is standing on the floor -- and
		-- writing the full authored DownVelocity onto a body with nowhere to fall drove every part
		-- through the floor surface in one physics step and let penetration recovery eject it upward in
		-- pieces. See Constants.Combat.Ragdoll.SlamGroundCheckDistance / RagdollController's
		-- resolveSlamScale.
		it(
			"clamps the slam's DOWN VELOCITY to SlamMinDownVelocity for a grounded target, "
				.. "but still applies the full face-down spin",
			function()
				local downSpeed, angular, immediateGroundImpact = slamDownSpeedWithFloorBelow(1)

				-- Nowhere to fall -> the authored 140 must NOT be applied.
				expect(downSpeed < 140).to.equal(true)
				expect(downSpeed).to.equal(Constants.Combat.Ragdoll.SlamMinDownVelocity)
				-- ...but still fast enough to trip SlamImpactVFX's fall-then-arrest detection, or a grounded
				-- slam would land with no dust/debris/ring at all.
				expect(downSpeed > Constants.FX.SlamImpact.FastFallSpeedThreshold).to.equal(true)
				-- Unlike the velocity, the face-down PITCH is never clamped by ground clearance -- a standing
				-- body has its own height to rotate through regardless of what's underneath it, and that
				-- pitch (not vertical travel, which has nowhere to go here) is what actually sells "slammed
				-- to the ground" for a grounded target. See SlamToGround's own header for the full reasoning
				-- -- an earlier pass scaled this down alongside the velocity and it read as no impact at all.
				expect(math.abs(angular.Magnitude - 9) < 1e-4).to.equal(true)
				-- Regression: 0 studs of usable drop means the fall-and-arrest cycle above resolves within
				-- a single physics step -- too fast for Client/FX/SlamImpactVFX's own Heartbeat-rate poll
				-- to reliably observe (see SlamImmediateImpactDropStuds' own header). SlamToGround must
				-- report this as immediate so the client skips detection and just shows the impact.
				expect(immediateGroundImpact).to.equal(true)
			end
		)

		it("still applies the full authored slam to a target with real height beneath them", function()
			-- 20 studs of clearance (1 of it resting height) clears the penetration guard outright:
			-- 19 / (1/15) = 285 studs/s of headroom against an authored 140. This is the air-combo
			-- MaxHits slam from HoverHeight, which must keep landing at full force.
			local downSpeed, angular, immediateGroundImpact = slamDownSpeedWithFloorBelow(20)

			expect(downSpeed).to.equal(140)
			expect(math.abs(angular.Magnitude - 9) < 1e-4).to.equal(true)
			-- A genuine, observable fall -- must NOT be marked immediate, or the client would skip the
			-- (correctly working, per the whole point of this test) fall-then-arrest detection for it.
			expect(immediateGroundImpact).to.equal(false)
		end)

		it("scales the slam's down velocity proportionally for a target with only partial clearance", function()
			-- 7 studs of clearance -> 6 usable -> 6 / (1/15) = 90 studs/s, comfortably between the 50
			-- floor and the authored 140, so this exercises the genuinely proportional middle of the
			-- curve rather than either clamp endpoint.
			local downSpeed, _angular, immediateGroundImpact = slamDownSpeedWithFloorBelow(7)

			expect(math.abs(downSpeed - 90) < 1e-4).to.equal(true)
			-- 6 usable studs is well clear of SlamImmediateImpactDropStuds (1.5) -- a real, if short, fall.
			expect(immediateGroundImpact).to.equal(false)
		end)

		it("falls back to the target's own reversed facing when no attackerRootPart is given", function()
			local model, humanoid, rootPart = makeRig()
			-- Default Part CFrame is CFrame.identity -- LookVector (0, 0, -1), so the fallback
			-- direction (-LookVector) is (0, 0, 1), the mirror image of the attacker-relative case
			-- above and so the opposite-signed (+X) angular velocity.
			local faceDownSpin = 9

			RagdollController.SlamToGround(model, humanoid, rootPart, nil, nil, {
				DownVelocity = 140,
				FaceDownSpin = faceDownSpin,
				KnockdownSeconds = 1.25,
			})

			local angular = rootPart.AssemblyAngularVelocity
			expect(math.abs(angular.Magnitude - faceDownSpin) < 1e-4).to.equal(true)
			expect(angular.X > 0).to.equal(true)
		end)
	end)

	describe("RagdollController.LaunchAndRagdoll", function()
		-- Regression for "the uppercut makes the body spin and flip instead of flying." enterRagdoll
		-- splits the character into independent ball-socketed assemblies; a launch written onto the ROOT
		-- alone leaves every limb at its old velocity, and the sockets have to reconcile that mismatch on
		-- the very first physics step. SlamToGround always wrote to every part -- LaunchAndRagdoll did
		-- not, so the uppercut carried exactly the defect the slam's own comment describes.
		it("applies the launch velocity uniformly to every BasePart, not just the root", function()
			local model, humanoid, rootPart = makeRig()
			local limb = Instance.new("Part")
			limb.Name = "Limb"
			limb.Parent = model

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 55,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 2.5,
			})

			expect(rootPart.AssemblyLinearVelocity.Y).to.equal(55)
			expect(limb.AssemblyLinearVelocity.Y).to.equal(55)

			RagdollController.Recover(model)
			model:Destroy()
		end)

		-- Containment guard, not a feel knob -- an authored Move Editor knockback must not be able to
		-- fire a body clean off the map. See Constants.Combat.Ragdoll.MaxLaunchSpeed.
		it("clamps an absurd authored launch to MaxLaunchSpeed", function()
			local model, humanoid, rootPart = makeRig()

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 100000,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 1,
			})

			expect(rootPart.AssemblyLinearVelocity.Magnitude).to.equal(Constants.Combat.Ragdoll.MaxLaunchSpeed)

			RagdollController.Recover(model)
			model:Destroy()
		end)
	end)

	-- ExtendRagdoll's return value is what CombatSystem's object stun branches on before it pins a
	-- wall-slammed target: a silent no-op there left an AlignPosition arguing with a live,
	-- client-simulated body, which is why that pin "didn't stick to the wall at all". The three cases
	-- below are exactly the three answers that caller needs to be able to tell apart.
	describe("RagdollController.ExtendRagdoll", function()
		it("reports true and pushes the expiry out on a limp body", function()
			local model, humanoid, rootPart, _rootJoint, shoulder = makeJointedRig()

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 1,
			})

			expect(RagdollController.ExtendRagdoll(model, 30)).to.equal(true)

			-- Well past the ORIGINAL one-second window but inside the extended one: still limp, no
			-- recovery blend opened. Without the extension this same tick would have started the getup.
			RagdollController.Update(os.clock() + 5)
			expect(shoulder.Enabled).to.equal(false)
			expect((shoulder.Part1 :: BasePart):FindFirstChildOfClass("AlignOrientation")).to.equal(nil)

			RagdollController.Recover(model)
			model:Destroy()
		end)

		it("reports false for a character that was never ragdolled", function()
			local model = makeJointedRig()

			expect(RagdollController.ExtendRagdoll(model, 5)).to.equal(false)

			model:Destroy()
		end)

		-- The deliberate limit in its own header: a body already committed to standing up is NOT
		-- re-limped by an extension. The caller is told so rather than left believing it worked.
		it("reports false once the body is blending back upright, and does not cancel the blend", function()
			local model, humanoid, rootPart, _rootJoint, shoulder = makeJointedRig()

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 1,
			})

			local expired = os.clock() + 10
			RagdollController.Update(expired)
			expect((shoulder.Part1 :: BasePart):FindFirstChildOfClass("AlignOrientation")).to.be.ok()

			expect(RagdollController.ExtendRagdoll(model, 30)).to.equal(false)

			-- The refused extension must not have kept the body down either -- the blend still finishes.
			RagdollController.Update(expired + Constants.Combat.Ragdoll.RecoverBlendSeconds + 0.01)
			expect(shoulder.Enabled).to.equal(true)

			model:Destroy()
		end)
	end)

	describe("RagdollController joint swap and recovery blend", function()
		it(
			"ball-sockets every joint that does NOT touch the HumanoidRootPart, and leaves the root joint rigid",
			function()
				local model, humanoid, rootPart, rootJoint, shoulder = makeJointedRig()

				RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
					UpVelocity = 0,
					HorizontalVelocity = 0,
					BackwardSpin = 0,
					RagdollSeconds = 1,
				})

				expect(rootJoint.Enabled).to.equal(true)
				expect(shoulder.Enabled).to.equal(false)
				expect((shoulder.Part0 :: BasePart):FindFirstChildOfClass("BallSocketConstraint")).to.be.ok()

				RagdollController.Recover(model)
				model:Destroy()
			end
		)

		-- The headline smoothness change. Re-enabling a Motor6D teleports its limb from wherever physics
		-- left it to wherever the animation says it belongs, which from a sprawled ragdoll is a large,
		-- very visible pop on every client. Recovery now spends RecoverBlendSeconds physically folding
		-- the body back first, so the motors come back to a pose that is already almost right.
		it("enters a blend phase on expiry and only re-enables the motors once it elapses", function()
			local model, humanoid, rootPart, _rootJoint, shoulder = makeJointedRig()

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 1,
			})

			-- Well past the authored window: this opens the blend, it does NOT finish the recovery.
			local expired = os.clock() + 10
			RagdollController.Update(expired)
			expect(shoulder.Enabled).to.equal(false)
			expect((shoulder.Part1 :: BasePart):FindFirstChildOfClass("AlignOrientation")).to.be.ok()
			expect(rootPart:FindFirstChild("RagdollUprightAlign")).to.be.ok()

			-- Mid-blend: still limp, drives ramping in.
			RagdollController.Update(expired + Constants.Combat.Ragdoll.RecoverBlendSeconds * 0.5)
			expect(shoulder.Enabled).to.equal(false)

			-- Blend elapsed: motors back, every created instance gone.
			RagdollController.Update(expired + Constants.Combat.Ragdoll.RecoverBlendSeconds + 0.01)
			expect(shoulder.Enabled).to.equal(true)
			expect((shoulder.Part0 :: BasePart):FindFirstChildOfClass("BallSocketConstraint")).to.equal(nil)
			expect(rootPart:FindFirstChild("RagdollUprightAlign")).to.equal(nil)
			expect(humanoid.PlatformStand).to.equal(false)

			model:Destroy()
		end)

		it("re-limps a body hit again mid-blend instead of letting it finish standing up", function()
			local model, humanoid, rootPart, _rootJoint, shoulder = makeJointedRig()

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 1,
			})

			local expired = os.clock() + 10
			RagdollController.Update(expired)
			expect((shoulder.Part1 :: BasePart):FindFirstChildOfClass("AlignOrientation")).to.be.ok()

			-- A second finisher lands mid-getup: the recovery drives must be torn down and the loose
			-- socket limits restored, or the body would keep folding itself upright through the new hit.
			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 2.5,
			})
			expect((shoulder.Part1 :: BasePart):FindFirstChildOfClass("AlignOrientation")).to.equal(nil)
			expect(shoulder.Enabled).to.equal(false)

			-- ...and it must NOT complete the old blend on the very next tick.
			RagdollController.Update(expired + Constants.Combat.Ragdoll.RecoverBlendSeconds + 0.01)
			expect(shoulder.Enabled).to.equal(false)

			RagdollController.Recover(model)
			model:Destroy()
		end)

		-- Standing a dead body back up is exactly the snap CombatSystem.confirmDeath goes out of its way
		-- to avoid; a corpse should stay where the hit left it.
		it("abandons a dead body limp rather than restoring its motors", function()
			local model, humanoid, rootPart, _rootJoint, shoulder = makeJointedRig()

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 1,
			})
			humanoid.Health = 0

			RagdollController.Recover(model)

			expect(shoulder.Enabled).to.equal(false)
			expect((shoulder.Part0 :: BasePart):FindFirstChildOfClass("BallSocketConstraint")).to.be.ok()

			model:Destroy()
		end)
	end)

	describe("RagdollController live-body hold", function()
		-- Regression for a hold that never existed. AlignOrientation.MaxTorque is a FLOAT (BodyGyro is
		-- the one that takes a Vector3), and the live-body face-orientation constraint was assigning a
		-- Vector3 -- inside HoldAloft's construction pcall, so the whole build failed and immediately
		-- tore itself back down. The air-combo attacker's chase pin and a live victim's hover pin were
		-- both silently absent.
		it("builds the full live-body constraint set (pin, gravity cancel, face orientation)", function()
			local _model, humanoid, rootPart = makeRig()

			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
				MaxSpeed = Constants.Combat.AirCombo.ChaseSpeed,
				Responsiveness = Constants.Combat.AirCombo.ChaseResponsiveness,
				LiveBodyFacePoint = Vector3.new(0, 12, 10),
			})

			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.be.ok()
			expect(rootPart:FindFirstChild("AirComboHoldGravityCancel")).to.be.ok()
			expect(rootPart:FindFirstChild("AirComboHoldOrient")).to.be.ok()
			-- The live body's own Humanoid is quieted for the duration, or its controller fights the pin
			-- every frame and the rise stutters instead of gliding.
			expect(humanoid.PlatformStand).to.equal(true)

			RagdollController.ClearHold(rootPart, nil)
			expect(#holdInstanceNames(rootPart)).to.equal(0)
			expect(humanoid.PlatformStand).to.equal(false)
		end)

		-- Regression for the permanent-limp stuck state. Both the hold and the ragdoll need the Humanoid
		-- suppressed, and a live-held victim who then eats a finisher is under both at once. Saving and
		-- restoring the Humanoid's own properties independently in each path meant the second one
		-- captured PlatformStand = true (set moments earlier by the first) as its "pristine" value and
		-- faithfully restored it -- leaving the player limp and unable to move for the rest of their
		-- life. Suppression is reference counted now: captured once by the first claim, restored once by
		-- the last release.
		it("restores Humanoid control exactly once when a hold and a ragdoll overlap on the same body", function()
			local model, humanoid, rootPart = makeRig()
			expect(humanoid.PlatformStand).to.equal(false)

			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
				LiveBodyFacePoint = Vector3.new(0, 12, 10),
			})
			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 55,
				HorizontalVelocity = 8,
				BackwardSpin = 6,
				RagdollSeconds = 2.5,
			})

			-- Releasing only ONE of the two claims must leave the body still suppressed.
			RagdollController.ClearHold(rootPart, nil)
			expect(humanoid.PlatformStand).to.equal(true)

			-- Releasing the last one hands control back.
			RagdollController.Recover(model)
			expect(humanoid.PlatformStand).to.equal(false)
			expect(humanoid.AutoRotate).to.equal(true)

			model:Destroy()
		end)

		-- ClearHold used to reset the whole character to the Default collision group unconditionally,
		-- which on a still-ragdolled body silently dropped the self-collision exemption that stops its
		-- own limbs from shoving each other apart -- precisely the case the air-combo slam finisher hits
		-- (ClearHold immediately before SlamToGround, on a target ragdolled since the opener).
		it("leaves a still-ragdolled body in the Ragdoll collision group when its hold is cleared", function()
			local model, humanoid, rootPart = makeRig()
			-- Parented: Recover only restores a character that's still in the world, so the "back to
			-- Default once the ragdoll ends" half of this test needs a genuinely live body.
			model.Parent = Workspace

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 2.5,
			})
			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = Constants.Combat.AirCombo.AirborneSeconds,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
			})

			RagdollController.ClearHold(rootPart, nil)
			expect(rootPart.CollisionGroup).to.equal("Ragdoll")

			-- ...and back to Default once the ragdoll itself is over.
			RagdollController.Recover(model)
			expect(rootPart.CollisionGroup).to.equal("Default")

			model:Destroy()
		end)

		-- The hold's own window is now enforced by Update rather than by a per-hold task.delay thread,
		-- and its release is the event the object stun's wall-drop hangs off. Two properties matter and
		-- neither is incidental: the callback fires when the window genuinely lapses, and it does NOT
		-- fire when a caller cancels the hold early -- a caller reaching ClearHold is taking the body
		-- over, and running "what happens when the pin lets go" underneath it is exactly the race the
		-- callback replaced.
		it("fires OnRelease when the hold's own window elapses, and not when a caller clears it early", function()
			local _model, _humanoid, rootPart = makeRig()
			local released = 0

			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = 0.5,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
				OnRelease = function()
					released += 1
				end,
			})

			-- Inside the window: nothing released, pin still standing.
			RagdollController.Update(os.clock())
			expect(released).to.equal(0)
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.be.ok()

			RagdollController.Update(os.clock() + 1)
			expect(released).to.equal(1)
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.equal(nil)

			-- The released hold is gone from the table, so a later tick can't fire it a second time.
			RagdollController.Update(os.clock() + 2)
			expect(released).to.equal(1)

			-- An early ClearHold takes the body over instead of running the release beat.
			local cancelled = 0
			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = 0.5,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
				OnRelease = function()
					cancelled += 1
				end,
			})
			RagdollController.ClearHold(rootPart, nil)
			RagdollController.Update(os.clock() + 1)
			expect(cancelled).to.equal(0)
		end)
	end)

	-- A knockdown's authored window is "how long they're down", but a real launch spends much of it
	-- still IN THE AIR. Recovering on the timer alone therefore opened the stand-up blend mid-flight,
	-- so the body folded itself upright while still travelling and landed neatly on its feet -- which
	-- reads as the knockback being shrugged off, the opposite of what a finisher is for.
	describe("RagdollController settle-aware recovery", function()
		it("keeps a still-moving body limp past its window, and stands it up once it stops", function()
			local model, humanoid, rootPart, _rootJoint, shoulder = makeJointedRig()

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 1,
			})

			-- Still travelling well above RecoverSettleSpeed when the authored window lapses.
			rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 90)
			local expired = os.clock() + 5
			RagdollController.Update(expired)
			expect(shoulder.Enabled).to.equal(false)
			expect((shoulder.Part1 :: BasePart):FindFirstChildOfClass("AlignOrientation")).to.equal(nil)
			expect(RagdollController.GetPhase(model)).to.equal("Limp")

			-- Come to rest: the very next tick opens the blend it was holding off on.
			rootPart.AssemblyLinearVelocity = Vector3.zero
			RagdollController.Update(expired + 0.05)
			expect(RagdollController.GetPhase(model)).to.equal("Blending")
			expect((shoulder.Part1 :: BasePart):FindFirstChildOfClass("AlignOrientation")).to.be.ok()

			RagdollController.Recover(model)
			model:Destroy()
		end)

		-- The bound on the wait above. A body that never comes to rest (knocked into a bottomless
		-- fall, onto a conveyor, into geometry the solver keeps nudging) must still recover rather
		-- than staying limp for the rest of its life.
		it("recovers anyway once RecoverSettleMaxSeconds has elapsed on a body that never settles", function()
			local model, humanoid, rootPart, _rootJoint, shoulder = makeJointedRig()

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 1,
			})

			rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 90)
			local expired = os.clock() + 5
			RagdollController.Update(expired)
			expect(RagdollController.GetPhase(model)).to.equal("Limp")

			RagdollController.Update(expired + Constants.Combat.Ragdoll.RecoverSettleMaxSeconds + 0.01)
			expect(RagdollController.GetPhase(model)).to.equal("Blending")
			expect((shoulder.Part1 :: BasePart):FindFirstChildOfClass("AlignOrientation")).to.be.ok()

			RagdollController.Recover(model)
			model:Destroy()
		end)
	end)

	describe("RagdollController.Ragdoll", function()
		-- The supported door for "make this body limp for this long", which callers used to have to
		-- spell as LaunchAndRagdoll with an all-zero LaunchProfile. The difference is real: that call
		-- wrote Vector3.zero across the whole body, stopping a target dead before the caller's own
		-- rebound/pin velocity had a chance to say what it should be doing instead. This one writes no
		-- velocity at all, so the momentum the body arrived with is carried onto every new assembly.
		it("makes a body limp without writing any velocity, preserving its momentum across the split", function()
			local model, humanoid, rootPart, _rootJoint, shoulder = makeJointedRig()
			local arm = shoulder.Part1 :: BasePart

			rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 40)
			RagdollController.Ragdoll(model, humanoid, rootPart, nil, 1.5)

			expect(shoulder.Enabled).to.equal(false)
			-- Seeded onto the limb's own brand-new assembly, not left behind on the torso.
			expect(math.abs(arm.AssemblyLinearVelocity.Z - 40) < 0.01).to.equal(true)
			expect(math.abs(rootPart.AssemblyLinearVelocity.Z - 40) < 0.01).to.equal(true)

			RagdollController.Recover(model)
			model:Destroy()
		end)
	end)

	-- The queries a caller needs in order to keep its own action lockout honest. CombatState.Vitals.
	-- ragdollExpiry exists specifically to mirror this module's timer, and a single timestamp stamped
	-- at hit time can no longer do that on its own now that recovery waits for a body to settle.
	describe("RagdollController queries", function()
		it("reports ragdoll, hold and remaining-time state, and stops reporting once recovered", function()
			local model, humanoid, rootPart = makeRig()
			model.Parent = Workspace

			expect(RagdollController.IsRagdolled(model)).to.equal(false)
			expect(RagdollController.GetPhase(model)).to.equal(nil)
			expect(RagdollController.RemainingSeconds(model, os.clock())).to.equal(0)
			expect(RagdollController.IsHeld(model)).to.equal(false)

			RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, {
				UpVelocity = 0,
				HorizontalVelocity = 0,
				BackwardSpin = 0,
				RagdollSeconds = 2,
			})

			expect(RagdollController.IsRagdolled(model)).to.equal(true)
			expect(RagdollController.GetPhase(model)).to.equal("Limp")
			-- The limp window still to run, plus the blend that always follows it.
			local remaining = RagdollController.RemainingSeconds(model, os.clock())
			expect(remaining > 2).to.equal(true)
			expect(remaining <= 2 + Constants.Combat.Ragdoll.RecoverBlendSeconds).to.equal(true)

			RagdollController.HoldAloft(rootPart, nil, {
				Position = Vector3.new(0, 12, 0),
				DurationSeconds = 1,
				MaxSpeed = Constants.Combat.AirCombo.HoverRiseSpeed,
				Responsiveness = Constants.Combat.AirCombo.HoverResponsiveness,
			})
			expect(RagdollController.IsHeld(model)).to.equal(true)
			RagdollController.ClearHold(rootPart, nil)
			expect(RagdollController.IsHeld(model)).to.equal(false)

			RagdollController.Recover(model)
			expect(RagdollController.IsRagdolled(model)).to.equal(false)
			expect(RagdollController.RemainingSeconds(model, os.clock())).to.equal(0)

			model:Destroy()
		end)
	end)
end
