--!strict
--[[
	SwingTrailAnchor.lua

	Owns: WHAT a swing's trail rides -- which limb (or the weapon) a given swing strikes with, and where on
	that part the trail's two Attachments go. Client/FX/SwingTrail.lua draws the trail; this decides where.

	THE LIMB BELONGS TO THE CLIP, so it is resolved against the stage whose clip actually plays, not the move
	that was thrown: an air beat with no clip of its own borrows an M1's (AttackAnimations.Resolve says
	which), and its trail follows that M1's hand. Resolution order, all data:
	  1. the weapon's own `TrailAnchor` Attribute on the slot folder that holds the clip
	     (Workspace.Weapons.<Id>.Animations.M2 -- the folder AttackAnimations.SlotFolderName names), so a
	     weapon that authors its own left-handed swing says so beside the clip;
	  2. AttackConstants.Presentation.SwingTrail.Anchors.<Unarmed|Armed>.ByStage[stage];
	  3. that table's Default -- the weapon for an armed swing, the right hand for a bare one.
	Fists (and an art cast empty-handed) are Unarmed; anything else in hand is Armed.

	WHERE ON THE PART. A limb's pair sits on its long axis around its TIP: the rig's own grip/foot
	Attachment when it has one (an R6 Right Arm's RightGripAttachment), the end of the part otherwise --
	THIS IS AN R6 GAME, so the "hand" is the last half-stud of the arm. A weapon's pair is, best first: a
	TrailNear/TrailFar Attachment pair its author placed in the model (the conventional way to author a
	weapon trail, and the only one that follows an oddly shaped blade exactly); the full length of its
	"Blade" part along that part's longest axis (the part HitboxAnchor resolves "Weapon" to); or a fixed
	run down the Handle's -Z. A weapon whose Tool has not replicated yet (a draw and a swing in the same
	instant) falls back to the right hand rather than drawing nothing -- HitboxAnchor's own fallback.

	Pure over the Instance tree it is handed (plus AttackAnimations' Workspace.Weapons read for the
	authored Attribute and the borrowed clip): no services of its own, no state, so Tests/FX/
	SwingTrail.spec can pin every answer on a real R6 rig.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackAnimations = require(ReplicatedStorage.Shared.Attack.AttackAnimations)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local logger = Logger.scope("SwingTrailAnchor")

local TUNING = AttackConstants.Presentation.SwingTrail

local SwingTrailAnchor = {}

export type Anchor = "RightArm" | "LeftArm" | "RightLeg" | "LeftLeg" | "Weapon"

-- Where the trail goes for one swing. Part is what the Trail is parented to. Near/Far are an authored pair
-- to use as they are; when they are nil, the trail's own pair goes on Part at NearOffset/FarOffset.
export type Target = {
	Anchor: Anchor,
	Part: BasePart,
	Near: Attachment?,
	Far: Attachment?,
	NearOffset: CFrame,
	FarOffset: CFrame,
}

-- R6 part names, and the rig Attachment at each limb's tip.
local LIMBS: { [string]: { Part: string, Tip: string } } = {
	RightArm = { Part = "Right Arm", Tip = "RightGripAttachment" },
	LeftArm = { Part = "Left Arm", Tip = "LeftGripAttachment" },
	RightLeg = { Part = "Right Leg", Tip = "RightFootAttachment" },
	LeftLeg = { Part = "Left Leg", Tip = "LeftFootAttachment" },
}

-- `value` as an Anchor, or nil for anything that is not one (an unset Attribute, a typo, a number).
function SwingTrailAnchor.Parse(value: unknown): Anchor?
	if value == "Weapon" or (typeof(value) == "string" and LIMBS[value] ~= nil) then
		return value :: Anchor
	end
	return nil
end

-- The stage key of a swing ("Basic:2", "Heavy:1", "Finisher", "Air:3"...) -- AttackAnimations' own key, so
-- a weapon's slot folder and the ByStage tables line up. From the MoveId for a weapon-stage id; otherwise
-- from Kind/StageIndex for the two strings (StageIndex 0 is the Finisher); nil for anything else (a
-- standalone or a custom hotbar move), which takes the Default.
function SwingTrailAnchor.StageKey(moveId: string, kind: string, stageIndex: number): string?
	local stage = string.match(moveId, "^default:[^:]+:(.+)$")
	if stage then
		return stage
	end
	if kind == "Basic" and stageIndex == 0 then
		return "Finisher"
	end
	if (kind == "Basic" or kind == "Heavy") and stageIndex > 0 then
		return `{kind}:{stageIndex}`
	end
	return nil
end

-- StageKey, moved to the stage whose clip this swing actually plays when it borrows one (see the header).
function SwingTrailAnchor.ClipStageKey(moveId: string, kind: string, stageIndex: number): string?
	local stage = SwingTrailAnchor.StageKey(moveId, kind, stageIndex)
	if stage == nil or not string.match(moveId, "^default:") then
		return stage
	end
	local _, lender = AttackAnimations.Resolve(moveId)
	if lender then
		return string.match(lender, "^default:[^:]+:(.+)$") or stage
	end
	return stage
end

-- Whether a swing thrown with `weaponId` in hand is an armed one. Fists and an empty hand are not.
function SwingTrailAnchor.IsArmed(weaponId: string?): boolean
	return weaponId ~= nil and weaponId ~= WeaponRoster.FISTS_ID
end

-- The Anchor a weapon model authors for `stage` on its slot folder, or nil when it authors none.
function SwingTrailAnchor.AuthoredFor(weaponModel: Instance?, stage: string?): Anchor?
	if weaponModel == nil or stage == nil then
		return nil
	end
	local folderName = AttackAnimations.SlotFolderName(stage)
	local animations = weaponModel:FindFirstChild("Animations")
	local slot = if folderName and animations then animations:FindFirstChild(folderName) else nil
	if not slot then
		return nil
	end
	local raw = slot:GetAttribute(TUNING.AnchorAttribute)
	local anchor = SwingTrailAnchor.Parse(raw)
	if raw ~= nil and anchor == nil then
		logger:warn("Unknown TrailAnchor on a weapon's slot folder; using the default", {
			path = slot:GetFullName(),
			value = tostring(raw),
		})
	end
	return anchor
end

-- Steps 1-3 of the header, given what was read: the authored Anchor wins, then the stage's entry, then
-- the table's Default.
function SwingTrailAnchor.Resolve(stage: string?, armed: boolean, authored: Anchor?): Anchor
	if authored then
		return authored
	end
	local tableFor = if armed then TUNING.Anchors.Armed else TUNING.Anchors.Unarmed
	local fromStage = if stage then SwingTrailAnchor.Parse(tableFor.ByStage[stage]) else nil
	return fromStage or SwingTrailAnchor.Parse(tableFor.Default) or "RightArm"
end

-- The whole answer for one swing, from the fields of its AttackStartedPayload.
function SwingTrailAnchor.ForSwing(moveId: string, kind: string, stageIndex: number, weaponId: string?): Anchor
	local stage = SwingTrailAnchor.ClipStageKey(moveId, kind, stageIndex)
	local container = if weaponId then WeaponAssets.Container(logger) else nil
	local model = if container and weaponId then container:FindFirstChild(weaponId) else nil
	return SwingTrailAnchor.Resolve(
		stage,
		SwingTrailAnchor.IsArmed(weaponId),
		SwingTrailAnchor.AuthoredFor(model, stage)
	)
end

-- A limb's pair, in that limb's own space: up the long axis from the tip, and a touch past it.
function SwingTrailAnchor.LimbSpan(part: BasePart, anchor: Anchor): (CFrame, CFrame)
	local limb = LIMBS[anchor]
	local tipAttachment = if limb then part:FindFirstChild(limb.Tip) else nil
	local tip = if tipAttachment and tipAttachment:IsA("Attachment")
		then tipAttachment.Position
		else Vector3.new(0, -part.Size.Y / 2, 0)
	local span = TUNING.LimbTip
	return CFrame.new(tip + Vector3.yAxis * span.BackStuds), CFrame.new(tip - Vector3.yAxis * span.PastStuds)
end

-- A blade's pair: end to end along the part's longest axis, through its centre.
function SwingTrailAnchor.EdgeSpan(size: Vector3): (CFrame, CFrame)
	local axis = Vector3.zAxis * size.Z / 2
	if size.X >= size.Y and size.X >= size.Z then
		axis = Vector3.xAxis * size.X / 2
	elseif size.Y >= size.Z then
		axis = Vector3.yAxis * size.Y / 2
	end
	return CFrame.new(axis), CFrame.new(-axis)
end

local function findPart(parent: Instance, name: string, recursive: boolean?): BasePart?
	local found = parent:FindFirstChild(name, recursive)
	return if found and found:IsA("BasePart") then found else nil
end

local function limbTarget(character: Model, anchor: Anchor): Target?
	local limb = LIMBS[anchor]
	local part = if limb then findPart(character, limb.Part) else nil
	if not part then
		return nil
	end
	local near, far = SwingTrailAnchor.LimbSpan(part, anchor)
	return { Anchor = anchor, Part = part, NearOffset = near, FarOffset = far }
end

local function weaponTarget(tool: Instance): Target?
	local names = TUNING.WeaponAttachmentNames
	local near = tool:FindFirstChild(names.Near, true)
	local far = tool:FindFirstChild(names.Far, true)
	if near and far and near:IsA("Attachment") and far:IsA("Attachment") then
		local holder = near.Parent
		if holder and holder:IsA("BasePart") then
			return {
				Anchor = "Weapon",
				Part = holder,
				Near = near,
				Far = far,
				NearOffset = CFrame.identity,
				FarOffset = CFrame.identity,
			}
		end
	end
	local blade = findPart(tool, "Blade", true)
	if blade then
		local nearOffset, farOffset = SwingTrailAnchor.EdgeSpan(blade.Size)
		return { Anchor = "Weapon", Part = blade, NearOffset = nearOffset, FarOffset = farOffset }
	end
	local handle = findPart(tool, "Handle")
	if handle then
		local offsets = TUNING.WeaponOffsetStuds
		return {
			Anchor = "Weapon",
			Part = handle,
			NearOffset = CFrame.new(0, 0, offsets.Near),
			FarOffset = CFrame.new(0, 0, offsets.Far),
		}
	end
	return nil
end

-- Where `anchor` puts the trail on `character`, or nil when the rig has no such part.
function SwingTrailAnchor.Target(character: Model, anchor: Anchor): Target?
	if anchor == "Weapon" then
		local tool = character:FindFirstChild(WeaponConstants.Visual.ToolName)
		local target = if tool then weaponTarget(tool) else nil
		return target or limbTarget(character, "RightArm")
	end
	return limbTarget(character, anchor)
end

return SwingTrailAnchor
