--!strict
-- Covers Client/Parkour/ParkourMotor.lua against the REAL engine, on a throwaway character.
--
-- WHY THIS SPEC EXISTS, specifically. A live playtest hit
-- `RelativeTo is not a valid member of AlignOrientation` -- that property exists on LinearVelocity and
-- VectorForce but not on AlignOrientation. It threw inside rig creation, ParkourController's own pcall
-- caught it, the body was released, and slide and wall-run silently did nothing. Nothing could have
-- caught it earlier: selene does not know Roblox property names, stylua does not care, and every other
-- parkour spec is deliberately Instance-free.
--
-- So this one is deliberately NOT Instance-free. It builds an actual Humanoid + HumanoidRootPart and
-- drives every motor mode, which means every constraint is really constructed and every property is
-- really assigned by the engine. Any future typo'd or hallucinated property name fails here rather
-- than in a playtest.
--
-- It is also the only spec in this feature that touches Workspace, so it cleans up after itself
-- rigorously -- a leaked character in the test place would be visible to every spec that runs after it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local ParkourMotor = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.ParkourMotor)
local Constants = require(ReplicatedStorage.Shared.Constants)

local ATTACHMENT_NAME = "ParkourAttachment"
local VELOCITY_DRIVE_NAME = "ParkourVelocityDrive"
local POSITION_DRIVE_NAME = "ParkourPositionDrive"
local ORIENTATION_DRIVE_NAME = "ParkourOrientationDrive"
local GRAVITY_CANCEL_NAME = "ParkourGravityCancel"

type Rig = { Character: Model, Humanoid: Humanoid, RootPart: BasePart }

local function makeRig(): Rig
	local character = Instance.new("Model")
	character.Name = "ParkourMotorSpecCharacter"

	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Size = Vector3.new(2, 2, 1)
	rootPart.CFrame = CFrame.new(0, 50, 0)
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

return function()
	describe("ParkourMotor -- Velocity drive mode", function()
		it("builds the whole constraint rig without erroring on a bad property name", function()
			-- The regression test for the playtest bug. Every property the rig sets is assigned by the
			-- real engine here, so a name that does not exist throws inside this test rather than inside
			-- a movement frame.
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(0, 0, 26)
			command.CancelGravity = true
			command.FaceDirection = Vector3.new(0, 0, 1)

			expect(ParkourMotor.Apply()).to.equal(true)
			expect(ParkourMotor.GetActiveMode()).to.equal("Velocity")

			expect(rig.RootPart:FindFirstChild(ATTACHMENT_NAME)).never.to.equal(nil)
			expect(rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME)).never.to.equal(nil)
			expect(rig.RootPart:FindFirstChild(ORIENTATION_DRIVE_NAME)).never.to.equal(nil)

			destroyRig(rig)
		end)

		it("commands the velocity it was given", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(3, 0, 26)
			ParkourMotor.Apply()

			local drive = rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME) :: LinearVelocity
			expect(drive.VectorVelocity.Z).to.equal(26)
			expect(drive.VectorVelocity.X).to.equal(3)

			destroyRig(rig)
		end)

		it("creates the gravity cancel only while asked for it", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.CancelGravity = true
			ParkourMotor.Apply()
			expect(rig.RootPart:FindFirstChild(GRAVITY_CANCEL_NAME)).never.to.equal(nil)

			command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.CancelGravity = false
			ParkourMotor.Apply()
			-- Destroyed rather than zeroed, so a state that exits abnormally cannot leave a force behind
			-- holding the character up -- see setGravityCancel's own header.
			expect(rig.RootPart:FindFirstChild(GRAVITY_CANCEL_NAME)).to.equal(nil)

			destroyRig(rig)
		end)

		it("lowers HipHeight for a crouch and restores it on release", function()
			local rig = makeRig()
			local originalHipHeight = rig.Humanoid.HipHeight
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.HipHeightDelta = 1.6
			ParkourMotor.Apply()
			expect(rig.Humanoid.HipHeight < originalHipHeight).to.equal(true)

			ParkourMotor.Release()
			expect(rig.Humanoid.HipHeight).to.equal(originalHipHeight)

			destroyRig(rig)
		end)

		it("never inverts HipHeight even for an absurd crouch depth", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.HipHeightDelta = 999
			ParkourMotor.Apply()
			expect(rig.Humanoid.HipHeight > 0).to.equal(true)

			destroyRig(rig)
		end)

		it("captures and restores AutoRotate rather than assuming it was true", function()
			-- Shift lock owns AutoRotate while engaged (Client/Camera/ShiftLockCamera.lua writes it
			-- false); restoring a hardcoded true would silently break shift lock for the rest of the life.
			local rig = makeRig()
			rig.Humanoid.AutoRotate = false
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			ParkourMotor.Apply()
			expect(rig.Humanoid.AutoRotate).to.equal(false)

			ParkourMotor.Release()
			expect(rig.Humanoid.AutoRotate).to.equal(false)

			destroyRig(rig)
		end)
	end)

	describe("ParkourMotor -- Kinematic drive mode", function()
		it("builds a rigid, unanchored position rig and does not anchor the root", function()
			-- The regression test for the replication bug this mode was rewritten to fix: an anchored
			-- part never replicates to other clients, so Kinematic mode must never anchor. The
			-- constraint's own properties are also spot-checked here for the same reason the file
			-- header describes -- a bad property name (RigidityEnabled, Mode, Position) throws inside
			-- rig creation, which this catches immediately rather than in a playtest.
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local target = CFrame.new(10, 60, -4)
			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = target

			expect(ParkourMotor.Apply()).to.equal(true)
			expect(ParkourMotor.GetActiveMode()).to.equal("Kinematic")
			expect(rig.RootPart.Anchored).to.equal(false)

			local drive = rig.RootPart:FindFirstChild(POSITION_DRIVE_NAME)
			expect(drive).never.to.equal(nil)
			expect((drive :: AlignPosition).RigidityEnabled).to.equal(true)
			expect((drive :: AlignPosition).Position).to.equal(target.Position)
			expect(rig.RootPart:FindFirstChild(ORIENTATION_DRIVE_NAME)).never.to.equal(nil)

			destroyRig(rig)
		end)

		-- NOT COVERED HERE, AND WHY: whether a rigid AlignPosition actually converges onto its target
		-- over real physics (against gravity) and actually resists being deflected by solid geometry the
		-- target lands inside (the open question States/Vaulting.lua's own header raises -- an anchored
		-- CFrame write satisfied that guarantee by skipping collision resolution entirely).
		--
		-- Both were WRITTEN as real, physics-stepping specs here first -- construct the rig, command a
		-- target, `task.wait()`, assert the resulting Position converged -- and both FAILED even for the
		-- trivial case of an unconstrained part in free fall under gravity. Diagnosis: this suite runs
		-- via run-in-roblox executing a plugin script against an OPENED place, never an entered Play
		-- session -- `RunService:IsRunning()` is false, `Workspace:GetRealPhysicsFPS()` is 0, and
		-- `RunService.Stepped` (the physics step signal) never fires at all over a real half-second wait,
		-- even though `Heartbeat` does (18 times), which is what lets the timer-based waits elsewhere in
		-- this suite (Tests/FX/AnimationFreezeGuard.spec.lua's own `task.wait`) work despite physics never
		-- stepping. Every existing assertion in this file already worked within that limit without saying
		-- so -- e.g. "commands the velocity it was given" above checks the LinearVelocity constraint's own
		-- `VectorVelocity` property, never the root's resulting measured `Velocity` -- and the two tests
		-- that used to live here were the first in this file to actually need physics to run.
		--
		-- So this drive mode's dynamic behavior -- does it hold against gravity, does it resist a
		-- collision the anchored write it replaced was immune to -- is UNVERIFIED by this suite and needs
		-- a real Studio Play-mode session or a live playtest. What CAN be, and is, verified headlessly is
		-- everything above: the constraint is built with the right properties, on the right part, without
		-- ever anchoring it, and the rig tears down and rebuilds correctly across every mode transition.

		it("switching from Velocity to Kinematic drops the velocity rig and builds a position rig", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			ParkourMotor.Apply()
			expect(rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME)).never.to.equal(nil)

			command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = CFrame.new(0, 60, 0)
			ParkourMotor.Apply()

			expect(rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME)).to.equal(nil)
			expect(rig.RootPart:FindFirstChild(POSITION_DRIVE_NAME)).never.to.equal(nil)

			destroyRig(rig)
		end)

		it("refuses a kinematic frame with no target rather than driving toward nowhere", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = nil

			expect(ParkourMotor.Apply()).to.equal(false)
			expect(rig.RootPart.Anchored).to.equal(false)
			expect(rig.RootPart:FindFirstChild(POSITION_DRIVE_NAME)).to.equal(nil)

			destroyRig(rig)
		end)
	end)

	describe("ParkourMotor -- handing the body back", function()
		it("writes the exit velocity and tears the rig down when leaving an owned mode", function()
			-- Both happen inside one synchronous frame with no physics step in between, so the write
			-- lands before the rig that could otherwise fight it is gone. Kinematic mode no longer
			-- anchors, so this no longer depends on an unanchor-before-write ordering the way it used to
			-- -- see ParkourMotor.lua's own header on why that specific failure mode no longer applies.
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = CFrame.new(0, 60, 0)
			ParkourMotor.Apply()
			expect(rig.RootPart.Anchored).to.equal(false)

			command = ParkourMotor.BeginFrame()
			command.Mode = "Humanoid"
			command.Velocity = Vector3.new(0, 0, 30)
			ParkourMotor.Apply()

			expect(rig.RootPart.Anchored).to.equal(false)
			expect(rig.RootPart.AssemblyLinearVelocity.Z).to.equal(30)
			expect(rig.RootPart:FindFirstChild(POSITION_DRIVE_NAME)).to.equal(nil)
			expect(ParkourMotor.GetActiveMode()).to.equal("Humanoid")

			destroyRig(rig)
		end)

		it("Release clears the rig and every restorable, and leaves the root unanchored", function()
			local rig = makeRig()
			local originalHipHeight = rig.Humanoid.HipHeight
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = CFrame.new(0, 60, 0)
			command.HipHeightDelta = 1.6
			ParkourMotor.Apply()

			ParkourMotor.Release()

			expect(rig.RootPart.Anchored).to.equal(false)
			expect(rig.RootPart:FindFirstChild(ATTACHMENT_NAME)).to.equal(nil)
			expect(rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME)).to.equal(nil)
			expect(rig.RootPart:FindFirstChild(POSITION_DRIVE_NAME)).to.equal(nil)
			expect(rig.RootPart:FindFirstChild(ORIENTATION_DRIVE_NAME)).to.equal(nil)
			expect(rig.Humanoid.HipHeight).to.equal(originalHipHeight)
			expect(ParkourMotor.GetActiveMode()).to.equal("Humanoid")

			destroyRig(rig)
		end)

		it("is safe to Release repeatedly and while unbound", function()
			ParkourMotor.Unbind()
			ParkourMotor.Release()
			ParkourMotor.Release()
			expect(ParkourMotor.GetActiveMode()).to.equal("Humanoid")
		end)
	end)

	describe("ParkourMotor -- server root-control lock", function()
		it("refuses to drive the body while the server holds it", function()
			-- RootControlLocked is set by CombatSystem while a ragdoll or an air-combo hold owns the
			-- character; writing velocity underneath either is the exact fight this framework avoids.
			local rig = makeRig()
			rig.Humanoid:SetAttribute(Constants.Attributes.RootControlLocked, true)
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(0, 0, 26)

			expect(ParkourMotor.Apply()).to.equal(false)
			expect(rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME)).to.equal(nil)

			destroyRig(rig)
		end)

		it("releases an already-owned body the moment the lock appears", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			ParkourMotor.Apply()
			expect(rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME)).never.to.equal(nil)

			rig.Humanoid:SetAttribute(Constants.Attributes.RootControlLocked, true)
			command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			expect(ParkourMotor.Apply()).to.equal(false)
			expect(rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME)).to.equal(nil)

			destroyRig(rig)
		end)

		it("refuses an impulse while the server holds the body", function()
			local rig = makeRig()
			rig.Humanoid:SetAttribute(Constants.Attributes.RootControlLocked, true)
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			expect(ParkourMotor.ApplyImpulse(Vector3.new(0, 50, 0))).to.equal(false)

			destroyRig(rig)
		end)
	end)

	describe("ParkourMotor -- impulses and jump", function()
		it("writes an impulse straight onto the assembly", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			expect(ParkourMotor.ApplyImpulse(Vector3.new(0, 50, 12))).to.equal(true)
			expect(rig.RootPart.AssemblyLinearVelocity.Y).to.equal(50)

			destroyRig(rig)
		end)

		it("refuses an impulse during a kinematic traversal -- ownership of the body must not split", function()
			-- Kinematic mode no longer anchors, so this guard is keyed off GetActiveMode() rather than
			-- Anchored -- see ParkourMotor.ApplyImpulse's own header for why the contract (a kinematic
			-- traversal's ownership cannot be fought by a stray impulse) still has to hold exactly, not
			-- just "usually".
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = CFrame.new(0, 60, 0)
			ParkourMotor.Apply()
			expect(rig.RootPart.Anchored).to.equal(false)
			expect(ParkourMotor.GetActiveMode()).to.equal("Kinematic")

			expect(ParkourMotor.ApplyImpulse(Vector3.new(0, 50, 0))).to.equal(false)

			destroyRig(rig)
		end)

		it("reports jump availability from the Humanoid's own state-enabled flag", function()
			-- This is how CombatClient's finisher jump-suppression reaches the parkour system: it
			-- disables the Jumping state, and every parkour jump path has to honor that rather than
			-- jumping anyway through a velocity write.
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			rig.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
			expect(ParkourMotor.IsJumpEnabled()).to.equal(false)
			expect(ParkourMotor.RequestHumanoidJump()).to.equal(false)

			rig.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			expect(ParkourMotor.IsJumpEnabled()).to.equal(true)

			destroyRig(rig)
		end)
	end)

	describe("ParkourMotor -- planar drive", function()
		it("drives only the horizontal plane when asked, leaving the vertical to gravity", function()
			-- A real engine assignment of every Plane-mode property, for the same reason this file exists:
			-- a hallucinated name (PlaneVelocity, PrimaryTangentAxis, SecondaryTangentAxis) throws here.
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(4, -8, 20)
			command.PlanarOnly = true
			expect(ParkourMotor.Apply()).to.equal(true)

			local drive = rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME) :: LinearVelocity
			expect(drive.VelocityConstraintMode).to.equal(Enum.VelocityConstraintMode.Plane)
			expect(drive.PlaneVelocity.X).to.equal(4)
			expect(drive.PlaneVelocity.Y).to.equal(20)
			-- The plane's axes are world X and Z, so Y is the one axis the drive exerts no force along.
			expect(drive.PrimaryTangentAxis:Dot(Vector3.yAxis)).to.equal(0)
			expect(drive.SecondaryTangentAxis:Dot(Vector3.yAxis)).to.equal(0)

			destroyRig(rig)
		end)

		it("returns to a full vector drive the frame planar is no longer asked for", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(0, 0, 20)
			command.PlanarOnly = true
			ParkourMotor.Apply()

			command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(0, -8, 20)
			ParkourMotor.Apply()

			local drive = rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME) :: LinearVelocity
			expect(drive.VelocityConstraintMode).to.equal(Enum.VelocityConstraintMode.Vector)
			expect(drive.VectorVelocity.Y).to.equal(-8)

			destroyRig(rig)
		end)

		it("resets PlanarOnly every frame, so a state that does not ask gets the vector drive", function()
			local command = ParkourMotor.BeginFrame()
			command.PlanarOnly = true
			expect(ParkourMotor.BeginFrame().PlanarOnly).to.equal(false)
		end)
	end)

	describe("ParkourMotor -- external impulses interrupt a velocity state", function()
		it("records an interrupt for an external impulse while a Velocity state owns the body", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(0, 0, 30)
			ParkourMotor.Apply()

			local knock = Vector3.new(40, 25, 0)
			expect(ParkourMotor.ApplyExternalImpulse(knock)).to.equal(true)
			expect(ParkourMotor.ConsumeInterrupt()).to.equal(knock)
			-- Cleared by the read.
			expect(ParkourMotor.ConsumeInterrupt()).to.equal(nil)

			destroyRig(rig)
		end)

		it("records nothing for a state's own impulse, or while the engine drives", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			ParkourMotor.BeginFrame()
			ParkourMotor.Apply()
			expect(ParkourMotor.ApplyExternalImpulse(Vector3.new(10, 0, 0))).to.equal(true)
			expect(ParkourMotor.ConsumeInterrupt()).to.equal(nil)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(0, 0, 30)
			ParkourMotor.Apply()
			ParkourMotor.ApplyImpulse(Vector3.new(0, 50, 0))
			expect(ParkourMotor.ConsumeInterrupt()).to.equal(nil)

			destroyRig(rig)
		end)

		it("drops an unread interrupt when the body is handed back", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.Velocity = Vector3.new(0, 0, 30)
			ParkourMotor.Apply()
			ParkourMotor.ApplyExternalImpulse(Vector3.new(40, 0, 0))

			ParkourMotor.BeginFrame()
			ParkourMotor.Apply()
			expect(ParkourMotor.ConsumeInterrupt()).to.equal(nil)

			destroyRig(rig)
		end)
	end)

	describe("ParkourMotor.IsFacingHeldElsewhere", function()
		it("reads the AutoRotate the rest of the game left, not the one this module wrote", function()
			local rig = makeRig()
			rig.Humanoid.AutoRotate = true
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			expect(ParkourMotor.IsFacingHeldElsewhere()).to.equal(false)

			-- Owning the body writes AutoRotate false itself; that must not read as shift lock.
			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			ParkourMotor.Apply()
			expect(rig.Humanoid.AutoRotate).to.equal(false)
			expect(ParkourMotor.IsFacingHeldElsewhere()).to.equal(false)

			destroyRig(rig)
		end)

		it("says yes when shift lock had AutoRotate off before the body was taken", function()
			local rig = makeRig()
			rig.Humanoid.AutoRotate = false
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)
			expect(ParkourMotor.IsFacingHeldElsewhere()).to.equal(true)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			ParkourMotor.Apply()
			expect(ParkourMotor.IsFacingHeldElsewhere()).to.equal(true)

			destroyRig(rig)
		end)
	end)

	describe("ParkourMotor.BeginFrame", function()
		it("resets to a neutral Humanoid-driven frame, so a silent state hands the body back", function()
			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			command.HipHeightDelta = 5

			local next = ParkourMotor.BeginFrame()
			expect(next.Mode).to.equal("Humanoid")
			expect(next.HipHeightDelta).to.equal(0)
			expect(next.TargetCFrame).to.equal(nil)
			expect(next.Velocity).to.equal(Vector3.zero)
		end)

		it("returns the same reused table every frame rather than allocating", function()
			expect(ParkourMotor.BeginFrame()).to.equal(ParkourMotor.BeginFrame())
		end)
	end)
end
