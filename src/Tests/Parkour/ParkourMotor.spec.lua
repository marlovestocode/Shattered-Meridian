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
		it("anchors the root and drives it to the commanded CFrame", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local target = CFrame.new(10, 60, -4)
			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = target

			expect(ParkourMotor.Apply()).to.equal(true)
			expect(ParkourMotor.GetActiveMode()).to.equal("Kinematic")
			expect(rig.RootPart.Anchored).to.equal(true)
			expect(rig.RootPart.Position).to.equal(target.Position)

			destroyRig(rig)
		end)

		it("tears the constraint rig down -- an anchored part ignores it anyway", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Velocity"
			ParkourMotor.Apply()

			command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = CFrame.new(0, 60, 0)
			ParkourMotor.Apply()

			expect(rig.RootPart:FindFirstChild(VELOCITY_DRIVE_NAME)).to.equal(nil)

			destroyRig(rig)
		end)

		it("refuses a kinematic frame with no target rather than anchoring in place", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = nil

			expect(ParkourMotor.Apply()).to.equal(false)
			expect(rig.RootPart.Anchored).to.equal(false)

			destroyRig(rig)
		end)
	end)

	describe("ParkourMotor -- handing the body back", function()
		it("unanchors and writes the exit velocity when leaving an owned mode", function()
			-- The ordering that makes a vault's exit momentum survive: unanchor FIRST, then write the
			-- velocity. Writing it to an anchored part is silently discarded, which is what would turn
			-- every vault into a dead stop.
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = CFrame.new(0, 60, 0)
			ParkourMotor.Apply()
			expect(rig.RootPart.Anchored).to.equal(true)

			command = ParkourMotor.BeginFrame()
			command.Mode = "Humanoid"
			command.Velocity = Vector3.new(0, 0, 30)
			ParkourMotor.Apply()

			expect(rig.RootPart.Anchored).to.equal(false)
			expect(rig.RootPart.AssemblyLinearVelocity.Z).to.equal(30)
			expect(ParkourMotor.GetActiveMode()).to.equal("Humanoid")

			destroyRig(rig)
		end)

		it("Release clears the anchor, the rig and every restorable", function()
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

		it("refuses an impulse while the root is anchored -- it would be silently discarded", function()
			local rig = makeRig()
			ParkourMotor.BindCharacter(rig.Character, rig.Humanoid, rig.RootPart)

			local command = ParkourMotor.BeginFrame()
			command.Mode = "Kinematic"
			command.TargetCFrame = CFrame.new(0, 60, 0)
			ParkourMotor.Apply()

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
