--!strict
--[[
	WeaponAssets.lua

	Owns: how anything finds a weapon's authored content in the world -- the Workspace.Weapons folder
	itself, the asset-id form the engine actually accepts, and the walk from a weaponId down to one
	authored Animation in one named slot folder.

	WHY THIS EXISTS. Seven modules each resolved Workspace.Weapons for themselves, each declaring the
	literal "Weapons" again; four of them carried a byte-identical asset-id normaliser; two carried
	the same forty-line slot walk with the same six-step trace log. Several of their own comments
	already named the duplication and declined to fix it -- WeaponIdleAnimations' normalize() says
	outright that it is "identical to AttackAnimations.lua's own normalize()" and that sharing it
	would be "a cross-require for a handful of lines of pure string logic". That reasoning holds for
	two copies. It does not hold for four, and it never held for the container lookup, where the
	copies had ALREADY drifted: WeaponModelRegistry and WeaponRoster warn when Workspace.Weapons
	exists but is not a Folder, and the other four returned nil in silence -- so a misconfigured
	Workspace produced a loud diagnosis in two modules and a mystery in four.

	This module takes the strict behaviour: present-but-wrong-type always warns, through the CALLER's
	own logger scope so the line still attributes to the module that needed the folder.

	Does not own: what any weapon IS (Shared/Combat/WeaponRoster.lua's roster, WeaponModelRegistry's
	models), which slot names exist (each animation module's own folder-name table -- an attack stage,
	a defensive slot and an idle pose are different vocabularies), or loading a clip
	(Shared/Animation/AnimationManager.lua). It only answers "where is the content, and what is the
	id".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Logger = require(ReplicatedStorage.Shared.Logger)

local WeaponAssets = {}

-- The one place this name is written. It was written in six modules.
WeaponAssets.ContainerName = "Weapons"

-- Workspace.Weapons, or nil when it is absent or is not a Folder.
--
-- Absent is an ORDINARY state and is not warned about here: a place that has not had weapon models
-- placed in it yet is a legitimate configuration, and every caller already degrades to its own
-- baseline. Present-but-wrong-type is not ordinary -- somebody named a Model or a Part "Weapons" and
-- every weapon in the game silently stopped resolving -- so that one always warns.
function WeaponAssets.Container(logger: Logger.LoggerScope): Folder?
	local child = Workspace:FindFirstChild(WeaponAssets.ContainerName)
	if not child then
		return nil
	end
	if not child:IsA("Folder") then
		logger:warn("Workspace.Weapons exists but is not a Folder; ignoring", { className = child.ClassName })
		return nil
	end
	return child :: Folder
end

-- Accepts an asset id in either form an author might reasonably paste and returns the one the engine
-- actually understands.
--
-- WHY THIS IS NOT PEDANTRY. Roblox's own asset page, the Toolbox and the Creator Dashboard all show a
-- bare number, so a bare number is what gets copied -- but AnimationManager.resolveAssetId accepts a
-- registry key or a string matching "^rbxassetid://" and treats EVERYTHING ELSE as an unauthored
-- slot. A bare id therefore resolves to nil, the claim is refused, and the swing silently plays no
-- animation -- with no error, no warning, and a model that looks correctly filled in. That is the
-- worst possible failure for content whose whole promise is "paste an id here and it works".
--
-- Anything it does not recognise -- a typo, a name, a future content-id scheme -- is passed through
-- UNTOUCHED rather than guessed at: prefixing a malformed id would turn "this did nothing" into
-- "this points at someone else's asset", which is far harder to notice.
--
-- THREE FORMS, NOT TWO, and that third one is why this is a superset rather than a merge. Four
-- modules held a copy of this; three of them handled only the prefixed and bare-digit forms, and
-- WeaponSounds also handled the LEGACY ASSET URL that turns up on Sounds inside older imported
-- models -- its own comment said it was "deliberately NOT shared" for exactly that reason. Taking the
-- narrower three would have been a silent regression, and WeaponSounds.spec caught it. Taking the
-- wider one is not a regression in the other direction: a legacy URL on an Animation was already
-- broken, it just failed with the id passed through instead of resolved.
function WeaponAssets.NormalizeAssetId(assetId: string): string
	if assetId == "" then
		return ""
	end
	if string.match(assetId, "^rbxassetid://") then
		return assetId
	end
	-- A bare id, as displayed by the Creator Dashboard, the asset page and the Toolbox.
	if string.match(assetId, "^%d+$") then
		return string.format("rbxassetid://%s", assetId)
	end
	-- The legacy asset URL. Matched loosely (either scheme, with or without www, the id anywhere in
	-- the query) because every variant of it appears in the wild and all of them mean the same asset.
	local legacyId = string.match(assetId, "^https?://[%w%.%-]*roblox%.com/asset/?%?.*id=(%d+)")
	if legacyId then
		return string.format("rbxassetid://%s", legacyId)
	end
	return assetId
end

-- The Animation instance authored in `model`'s own Animations/<folderName> folder, or nil.
--
-- Whichever Animation instance sits directly in the folder is used regardless of its own Name -- one
-- clip per slot, so an Animation named "CutlassParry" and one named plain "Parry" resolve
-- identically.
function WeaponAssets.SlotAnimation(model: Instance, folderName: string): Animation?
	local animationsFolder = model:FindFirstChild("Animations")
	if not animationsFolder then
		return nil
	end
	local slotFolder = animationsFolder:FindFirstChild(folderName)
	if not slotFolder then
		return nil
	end
	return slotFolder:FindFirstChildOfClass("Animation") :: Animation?
end

-- The normalised AnimationId authored for `weaponId` in slot `folderName`, or nil when there is none.
--
-- LOGS THE FULL RESOLUTION CHAIN, not just the final answer, and that is the point of doing this in
-- one place. "My weapon's parry does nothing" has six indistinguishable causes from a caller's side
-- -- no such folder, no such weapon, no Animations folder, no slot subfolder, no Animation instance
-- in it, or a blank AnimationId -- five different authoring states needing five different fixes.
-- Both modules that used to own a copy of this walk said so in their own headers; one line differed
-- between them, the field name for the slot.
--
-- Called on weapon change and at boot, never per-frame, so a full trace every call costs nothing.
function WeaponAssets.ResolveAnimation(logger: Logger.LoggerScope, weaponId: string, folderName: string): string?
	local container = WeaponAssets.Container(logger)
	if not container then
		logger:debug("weaponOverride: Workspace.Weapons folder not found", { weaponId = weaponId, slot = folderName })
		return nil
	end
	local model = container:FindFirstChild(weaponId)
	if not model then
		logger:debug("weaponOverride: no child of Workspace.Weapons named this weaponId", {
			weaponId = weaponId,
			slot = folderName,
		})
		return nil
	end
	local animationsFolder = model:FindFirstChild("Animations")
	if not animationsFolder then
		logger:debug("weaponOverride: weapon model has no Animations folder", {
			weaponId = weaponId,
			slot = folderName,
			modelPath = model:GetFullName(),
		})
		return nil
	end
	local slotFolder = animationsFolder:FindFirstChild(folderName)
	if not slotFolder then
		logger:debug("weaponOverride: Animations folder has no subfolder for this slot", {
			weaponId = weaponId,
			slot = folderName,
			animationsPath = animationsFolder:GetFullName(),
		})
		return nil
	end
	local animation = slotFolder:FindFirstChildOfClass("Animation") :: Animation?
	if not animation then
		logger:debug("weaponOverride: slot folder has no Animation instance in it", {
			weaponId = weaponId,
			slot = folderName,
			slotFolderPath = slotFolder:GetFullName(),
		})
		return nil
	end
	if animation.AnimationId == "" then
		logger:debug("weaponOverride: Animation instance found, but its AnimationId is blank", {
			weaponId = weaponId,
			slot = folderName,
			animationPath = animation:GetFullName(),
		})
		return nil
	end
	local resolved = WeaponAssets.NormalizeAssetId(animation.AnimationId)
	logger:debug("weaponOverride: resolved", {
		weaponId = weaponId,
		slot = folderName,
		animationPath = animation:GetFullName(),
		rawAnimationId = animation.AnimationId,
		resolved = resolved,
	})
	return resolved
end

return WeaponAssets
