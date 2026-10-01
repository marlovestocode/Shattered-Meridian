--!strict
--[[
	HitboxAnchor.lua

	Owns: which part of a combatant a hitbox's Offset is composed against -- HitboxTypes.AttachmentPoint
	("Root" / "RightHand" / "LeftHand" / "Weapon") resolved to a real BasePart on a real rig.

	SHARED, AND ONE IMPLEMENTATION, because two things must agree on the answer: the server's HitboxEngine,
	which resolves it once when a swing's Active window opens, and the Move Editor's in-world preview
	(Client/DevTools/MoveEditor/HitboxWorldPreview.lua), which draws the volume on the admin's own
	character. A preview anchored by a second copy of this chain would be a preview that drifts from the
	hit the first time either copy changed. Lifted verbatim out of HitboxEngine.resolveAttachmentPart.

	FALLS BACK RATHER THAN FAILING: an R6 rig has no "RightHand", a character with no tool equipped has no
	weapon, and an attack authored for one rig should still swing on the other from the nearest sensible
	anchor instead of silently never hitting.

	Pure over the Instance tree it is handed: no services, no state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)

local HitboxAnchor = {}

local function findPart(model: Model, name: string): BasePart?
	local found = model:FindFirstChild(name)
	return if found and found:IsA("BasePart") then found else nil
end

function HitboxAnchor.Resolve(model: Model, rootPart: BasePart, attachment: HitboxTypes.AttachmentPoint): BasePart
	if attachment == "RightHand" then
		return findPart(model, "RightHand") or findPart(model, "Right Arm") or rootPart
	elseif attachment == "LeftHand" then
		return findPart(model, "LeftHand") or findPart(model, "Left Arm") or rootPart
	elseif attachment == "Weapon" then
		local tool = model:FindFirstChildOfClass("Tool")
		if tool then
			-- Blade first: WeaponModelRegistry's Model-wrapping path already lifts a part named "Blade"
			-- to be a direct child of the built Tool, the same promotion Handle itself gets (see that
			-- module's wrapModel), so a real weapon equipped through the normal pipeline carries its
			-- Blade straight into the Tool with zero extra wiring. Anchoring here rather than on Handle
			-- is what makes a swing's hitbox track and (with SizeFromAttachmentPart) size itself off the
			-- actual edge of the weapon instead of its grip. Searched at any depth, not just the direct
			-- child the Model path already guarantees, as a second line of defense for the OTHER
			-- authoring path -- a hand-authored Tool (buildMaster's passthrough case, which deliberately
			-- does not restructure anything) that nests its own Blade a level down. Handle remains the
			-- fallback for a weapon authored with no Blade part at all (a fist weapon, an old reskin).
			local blade = tool:FindFirstChild("Blade", true)
			if blade and blade:IsA("BasePart") then
				return blade
			end
			local handle = tool:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				return handle
			end
		end
		return findPart(model, "RightHand") or findPart(model, "Right Arm") or rootPart
	end
	return rootPart
end

return HitboxAnchor
