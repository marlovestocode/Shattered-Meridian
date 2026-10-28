--!strict
-- The swing trail: which limb each swing rides (Shared/Combat/SwingTrailAnchor) and where on it, pinned on a
-- real R6 rig, plus a real Trail built from AttackConstants.Presentation.SwingTrail property by property.
-- Roblox property names are unchecked until the engine touches them: the tuning table once carried `Width`,
-- which Trail does not have, and every swing in play threw. This spec is the engine touching it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local AttackAnimations = require(ReplicatedStorage.Shared.Attack.AttackAnimations)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local SwingTrailAnchor = require(ReplicatedStorage.Shared.Combat.SwingTrailAnchor)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local Rig = require(ServerScriptService.Tests.TestHelpers.Rig)

local TUNING = AttackConstants.Presentation.SwingTrail

local function fistSwing(stage: string, kind: string, stageIndex: number): SwingTrailAnchor.Anchor
	return SwingTrailAnchor.ForSwing(`default:Fists:{stage}`, kind, stageIndex, "Fists")
end

return function()
	afterEach(function()
		Rig.DestroyAll()
	end)

	describe("the Trail itself", function()
		it("sets only properties a Trail actually has", function()
			local part = Instance.new("Part")
			local a0 = Instance.new("Attachment")
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Parent = part

			local trail = Instance.new("Trail")
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Color = TUNING.Color
			trail.Transparency = TUNING.Transparency
			trail.WidthScale = TUNING.WidthScale
			trail.Lifetime = TUNING.LifetimeSeconds
			trail.LightEmission = TUNING.LightEmission
			trail.LightInfluence = TUNING.LightInfluence
			trail.Brightness = TUNING.Brightness
			trail.FaceCamera = TUNING.FaceCamera
			trail.Color = TUNING.FeintColor
			trail.Parent = part

			expect(trail.Lifetime).to.be.near(TUNING.LifetimeSeconds, 1e-4)
			part:Destroy()
		end)

		it("has no Width field for anything to try to set", function()
			expect((TUNING :: any).Width).to.equal(nil)
		end)

		it("loads the client module that draws it", function()
			local SwingTrail = require(StarterPlayer.StarterPlayerScripts.Client.FX.SwingTrail) :: any
			expect(typeof(SwingTrail.Start)).to.equal("function")
			expect(typeof(SwingTrail.BindCharacter)).to.equal("function")
		end)
	end)

	describe("which limb a swing rides", function()
		it("throws the bare-hands string right, left, right", function()
			expect(fistSwing("Basic:1", "Basic", 1)).to.equal("RightArm")
			expect(fistSwing("Basic:2", "Basic", 2)).to.equal("LeftArm")
			expect(fistSwing("Basic:3", "Basic", 3)).to.equal("RightArm")
		end)

		it("matches the clips: Basic:1 and Basic:3 share a clip, so they share a hand", function()
			expect(AttackAnimations.Get("default:Fists:Basic:1")).to.equal(
				AttackAnimations.Get("default:Fists:Basic:3")
			)
			expect(fistSwing("Basic:1", "Basic", 1)).to.equal(fistSwing("Basic:3", "Basic", 3))
		end)

		it("follows a borrowed clip's hand for an air beat", function()
			for beat = 1, 3 do
				local _, lender = AttackAnimations.Resolve(`default:Fists:Air:{beat}`)
				local expected = if lender then string.match(lender, "^default:[^:]+:(.+)$") else `Air:{beat}`
				expect(SwingTrailAnchor.ClipStageKey(`default:Fists:Air:{beat}`, "Basic", beat)).to.equal(expected)
			end
		end)

		it("keys a non-default move off its Kind and StageIndex", function()
			expect(SwingTrailAnchor.StageKey("custom:abc", "Basic", 2)).to.equal("Basic:2")
			expect(SwingTrailAnchor.StageKey("custom:abc", "Basic", 0)).to.equal("Finisher")
			expect(SwingTrailAnchor.StageKey("custom:abc", "Heavy", 1)).to.equal("Heavy:1")
			expect(SwingTrailAnchor.StageKey("custom:abc", "Hotbar", 0)).to.equal(nil)
			expect(SwingTrailAnchor.StageKey("default:DashPunch", "Hotbar", 0)).to.equal(nil)
			expect(SwingTrailAnchor.ForSwing("custom:abc", "Basic", 2, nil)).to.equal("LeftArm")
		end)

		it("falls back to the right hand bare, and to the weapon armed", function()
			expect(SwingTrailAnchor.ForSwing("custom:abc", "Hotbar", 0, nil)).to.equal("RightArm")
			expect(SwingTrailAnchor.Resolve("Heavy:1", false, nil)).to.equal(TUNING.Anchors.Unarmed.Default)
			expect(SwingTrailAnchor.Resolve("Basic:2", true, nil)).to.equal("Weapon")
			expect(SwingTrailAnchor.IsArmed("Fists")).to.equal(false)
			expect(SwingTrailAnchor.IsArmed(nil)).to.equal(false)
			expect(SwingTrailAnchor.IsArmed("Sword")).to.equal(true)
		end)

		it("lets a weapon's slot folder author the limb for its own clip", function()
			local model = Instance.new("Model")
			local animations = Instance.new("Folder")
			animations.Name = "Animations"
			animations.Parent = model
			local slot = Instance.new("Folder")
			slot.Name = AttackAnimations.SlotFolderName("Basic:2") :: string
			slot.Parent = animations
			slot:SetAttribute(TUNING.AnchorAttribute, "RightLeg")

			local authored = SwingTrailAnchor.AuthoredFor(model, "Basic:2")
			expect(authored).to.equal("RightLeg")
			expect(SwingTrailAnchor.Resolve("Basic:2", true, authored)).to.equal("RightLeg")
			expect(SwingTrailAnchor.AuthoredFor(model, "Basic:1")).to.equal(nil)

			slot:SetAttribute(TUNING.AnchorAttribute, "Right Hand")
			expect(SwingTrailAnchor.AuthoredFor(model, "Basic:2")).to.equal(nil)
			model:Destroy()
		end)

		it("authors only anchors that exist", function()
			expect(SwingTrailAnchor.Parse("Weapon")).to.equal("Weapon")
			expect(SwingTrailAnchor.Parse("Right Arm")).to.equal(nil)
			expect(SwingTrailAnchor.Parse(3)).to.equal(nil)
			for _, group in { TUNING.Anchors.Unarmed, TUNING.Anchors.Armed } do
				expect(SwingTrailAnchor.Parse(group.Default)).to.equal(group.Default)
				for stage, anchor in group.ByStage do
					expect(SwingTrailAnchor.Parse(anchor)).to.equal(anchor)
					expect(AttackAnimations.SlotFolderName(stage) ~= nil).to.equal(true)
				end
			end
		end)
	end)

	describe("where on the rig", function()
		it("puts each limb's pair at that limb's tip on a real R6 rig", function()
			local body = Rig.R6("TrailRig")
			for anchor, partName in { RightArm = "Right Arm", LeftArm = "Left Arm", RightLeg = "Right Leg" } do
				local target = SwingTrailAnchor.Target(body.Model, anchor :: SwingTrailAnchor.Anchor)
				assert(target, anchor)
				expect(target.Part.Name).to.equal(partName)
				expect(target.Near).to.equal(nil)
				local tipY = -target.Part.Size.Y / 2
				expect(target.NearOffset.Position.Y).to.be.near(tipY + TUNING.LimbTip.BackStuds, 0.05)
				expect(target.FarOffset.Position.Y).to.be.near(tipY - TUNING.LimbTip.PastStuds, 0.05)
			end
		end)

		it("draws a fist's trail as a thin line, and a blade's as a real edge", function()
			local fist = TUNING.LimbTip.BackStuds + TUNING.LimbTip.PastStuds
			local blade = math.abs(TUNING.WeaponOffsetStuds.Near - TUNING.WeaponOffsetStuds.Far)
			expect(fist > 0 and fist <= 0.5).to.equal(true)
			expect(blade > fist).to.equal(true)
		end)

		it("falls back to the right hand when an armed swing's Tool has not replicated", function()
			local body = Rig.R6("TrailRigUnarmed")
			local target = SwingTrailAnchor.Target(body.Model, "Weapon")
			assert(target, "no target")
			expect(target.Anchor).to.equal("RightArm")
			expect(target.Part.Name).to.equal("Right Arm")
		end)

		it("rides the weapon: authored pair, then Blade, then Handle", function()
			local body = Rig.R6("TrailRigArmed")
			local tool = Instance.new("Tool")
			tool.Name = WeaponConstants.Visual.ToolName
			local handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Parent = tool
			tool.Parent = body.Model

			local onHandle = SwingTrailAnchor.Target(body.Model, "Weapon")
			assert(onHandle, "no handle target")
			expect(onHandle.Part).to.equal(handle)
			expect(onHandle.FarOffset.Position.Z).to.be.near(TUNING.WeaponOffsetStuds.Far, 1e-4)

			local blade = Instance.new("Part")
			blade.Name = "Blade"
			blade.Size = Vector3.new(0.2, 0.4, 4)
			blade.Parent = tool
			local onBlade = SwingTrailAnchor.Target(body.Model, "Weapon")
			assert(onBlade, "no blade target")
			expect(onBlade.Part).to.equal(blade)
			expect(math.abs(onBlade.NearOffset.Position.Z - onBlade.FarOffset.Position.Z)).to.be.near(4, 1e-4)

			local near = Instance.new("Attachment")
			near.Name = TUNING.WeaponAttachmentNames.Near
			near.Parent = blade
			local far = Instance.new("Attachment")
			far.Name = TUNING.WeaponAttachmentNames.Far
			far.Parent = blade
			local onAuthored = SwingTrailAnchor.Target(body.Model, "Weapon")
			assert(onAuthored, "no authored target")
			expect(onAuthored.Near).to.equal(near)
			expect(onAuthored.Far).to.equal(far)
		end)

		it("spans a blade along its longest axis", function()
			local near, far = SwingTrailAnchor.EdgeSpan(Vector3.new(0.3, 5, 0.5))
			expect(near.Position.Y).to.be.near(2.5, 1e-4)
			expect(far.Position.Y).to.be.near(-2.5, 1e-4)
			expect(near.Position.X).to.equal(0)
		end)
	end)
end
