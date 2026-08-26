--!strict
--[[
	WeaponDefenseAnimations.lua

	Owns: which PARRY clip and which BLOCK-HOLD clip belong to a given weapon. Slots seven and eight of
	the per-weapon Animations convention Shared/Attack/AttackAnimations.lua's WEAPON_STAGE_FOLDERS
	(M1/M2/M3/HEAVY/FINISHER) opened and Shared/Combat/WeaponIdleAnimations.lua's IDLE extended -- read
	off real Animation instances in the weapon's own Animations/PARRY and Animations/BLOCK folders in
	Workspace.Weapons, the same "content lives on the model, not in a Lua table" contract all three
	established.

	THE TWO CLIPS ARE ONE PAIR, WHICH IS WHY THEY ARE ONE MODULE AND NOT TWO. A block press plays the
	parry clip ONCE and then hands the body to the block clip on a LOOP for as long as the key is held
	(Client/Defense/DefenseClient.lua's two-phase claim -- see DefenseConstants.BlockHoldAnimationId's
	own header for the sequencing). They are authored together, they have to pose-match at the seam or
	the handoff visibly pops, and a weapon that overrode one but not the other would crossfade from its
	own parry into the SHARED baseline guard. Resolving both here means one lookup site, one fallback
	rule, and one place a mismatch is visible.

	FALLS BACK TO A SHARED BASELINE, UNLIKE WeaponIdleAnimations. That module returns "" for an
	unauthored weapon on purpose -- there IS no baseline idle to fall back to, so Roblox's own default
	stand-still pose showing through is the right answer. Defense is the opposite case and takes
	AttackAnimations' shape instead: DefenseConstants.ParryAnimationId/BlockHoldAnimationId are a real,
	authored, working pair that every combatant used before this module existed, so an override that is
	absent must resolve to THEM, not to nothing. A weapon with no PARRY folder still blocks and still
	parries; it just does it with the shared clip.

	THE PARRY SLOT IS NOT COSMETIC, AND THIS IS THE ONE THING TO KNOW BEFORE AUTHORING ONE. A parry's
	live window comes from ParryStart/ParryClose markers on the parry clip itself
	(Shared/Defense/ParryWindows.lua -- there is deliberately no window length in DefenseConstants), so
	giving a weapon its own PARRY clip gives that weapon its own parry TIMING. An unmarked clip is
	fail-closed, not fail-soft: the block still works and the window never opens. Server/Combat/Defense/
	DefenseSystem.Init runs GetParryIds() below through ParryWindows.ValidateAll at boot precisely so an
	unmarked or unreachable clip is loud there instead of silent in a fight.

	The BLOCK slot IS purely cosmetic by contrast -- nothing reads markers off it and the server never
	sees the id at all. It is a looping full-body pose, and that difference is worth keeping straight:
	retiming a PARRY clip retunes the mechanic, retiming a BLOCK clip does not.

	READ DIRECTLY FROM Workspace.Weapons, NOT THROUGH WeaponRoster, for the identical reason
	AttackAnimations.lua and WeaponIdleAnimations.lua each give in their own headers: WeaponRoster.Start()
	only ever runs on the SERVER, and BOTH sides need this one -- the client to play the clips, the
	server to read the parry clip's markers -- so neither may depend on the other's cache. Workspace
	replicates to every client regardless, so this module keeps its own copy of the fixed-path lookup,
	the same duplication WeaponRoster.lua, WeaponModelRegistry.lua, AttackAnimations.lua and
	WeaponIdleAnimations.lua each already carry rather than centralising.

	Does not own: playing anything (Client/Defense/DefenseClient.lua claims both clips through
	Shared/Animation/AnimationManager.lua), what a parry window MEANS (Server/Combat/Defense/
	DefenseStateMachine.lua), how a window is extracted from a clip (ParryWindows.lua), or which weapon
	is currently drawn (Server/Combat/Weapon/WeaponInventorySystem.lua, echoed to the client over
	Weapon_InventoryChanged and to server subscribers over AttackRequestSystem.OnWeaponChanged).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("WeaponDefenseAnimations")

local WeaponDefenseAnimations = {}

-- The one fixed folder this module reads -- see its header on why this is kept as this module's own
-- copy rather than going through Shared/Combat/WeaponRoster.lua. Same constant, same reasoning, as
-- WeaponRoster.lua's, WeaponModelRegistry.lua's, AttackAnimations.lua's and WeaponIdleAnimations.lua's
-- own CONTAINER_NAME.
local WEAPONS_CONTAINER = "Weapons"

-- Slot key -> the subfolder of a weapon's own Animations folder that holds that clip. Exported below
-- as WeaponDefenseAnimations.Slots so Tests/TestHelpers/WeaponFixture.lua can install exactly these
-- two folders without a second copy of the literals drifting from this one.
local PARRY_FOLDER = "PARRY"
local BLOCK_FOLDER = "BLOCK"

WeaponDefenseAnimations.Slots = {
	Parry = PARRY_FOLDER,
	Block = BLOCK_FOLDER,
}

-- Workspace.Weapons itself, or nil if nobody has made it yet -- mirrors WeaponRoster.findContainer,
-- WeaponModelRegistry.findContainer, AttackAnimations.weaponsContainer and
-- WeaponIdleAnimations.weaponsContainer exactly, because this is the fifth module reading that one
-- fixed path and none of the five may assume any other has run.
local function weaponsContainer(): Folder?
	local child = Workspace:FindFirstChild(WEAPONS_CONTAINER)
	if not child or not child:IsA("Folder") then
		return nil
	end
	return child :: Folder
end

-- Accepts an asset id in either form an author might reasonably paste and returns the one the engine
-- actually understands. Identical to AttackAnimations.lua's and WeaponIdleAnimations.lua's own
-- normalize() -- see AttackAnimations' header for why a bare digits-only id is worth normalising
-- rather than requiring the "rbxassetid://" prefix by convention alone. Not shared between the three
-- files for the reason WeaponIdleAnimations already records: a handful of lines of pure string logic
-- with no state, where the cross-require would cost more than the duplication.
local function normalize(assetId: string): string
	if assetId == "" then
		return ""
	end
	if string.match(assetId, "^rbxassetid://") then
		return assetId
	end
	if string.match(assetId, "^%d+$") then
		return `rbxassetid://{assetId}`
	end
	return assetId
end

-- The Animation instance authored in `model`'s own Animations/<folderName> folder, or nil when the
-- model has no Animations folder, no such subfolder, or that folder holds no Animation instance.
-- Whichever Animation instance sits directly in the folder is used regardless of its own Name -- one
-- clip per slot, the same convention AttackAnimations.weaponOverride and
-- WeaponIdleAnimations.idleAnimation both keep, so an Animation named "CutlassParry" and one named
-- plain "Parry" resolve identically.
local function slotAnimation(model: Instance, folderName: string): Animation?
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

-- The clip authored in `weaponId`'s own slot folder, or nil when it has none.
--
-- LOGS THE FULL RESOLUTION CHAIN, not just the final answer -- the same reasoning
-- AttackAnimations.weaponOverride and WeaponIdleAnimations.Get each give for doing this, and it
-- matters MORE here than in either of them: "my weapon's parry does nothing" has six
-- indistinguishable causes from a caller's side (no such weapon, no Animations folder, no PARRY
-- subfolder, no Animation instance in it, a blank AnimationId, or a real clip carrying no
-- ParryStart/ParryClose markers), and only the first five are visible from here.
-- ParryWindows.ValidateAll is what reports the sixth. Called on weapon change and at boot, never
-- per-frame, so a full trace every call costs nothing.
local function weaponOverride(weaponId: string, folderName: string): string?
	local container = weaponsContainer()
	if not container then
		logger:debug("weaponOverride: Workspace.Weapons folder not found", {
			weaponId = weaponId,
			slot = folderName,
		})
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
	local resolved = normalize(animation.AnimationId)
	logger:debug("weaponOverride: resolved", {
		weaponId = weaponId,
		slot = folderName,
		animationPath = animation:GetFullName(),
		rawAnimationId = animation.AnimationId,
		resolved = resolved,
	})
	return resolved
end

-- One slot's answer for one weapon: the weapon's own clip if it has one, otherwise the shared baseline
-- -- see this file's header on why this falls back where WeaponIdleAnimations returns "". A nil/empty
-- weaponId (nobody armed, or a sheathed weapon) skips the lookup entirely and takes the baseline, which
-- is exactly what an unarmed combatant should block with.
--
-- Never nil and never errors on an unknown weapon. Can still return "" -- when the baseline itself is
-- blank, which is the pre-asset state every animation table in this codebase uses "" to mean.
local function resolve(weaponId: string?, folderName: string, baseline: string): string
	if typeof(weaponId) ~= "string" or weaponId == "" then
		return normalize(baseline)
	end
	local override = weaponOverride(weaponId, folderName)
	if override then
		return override
	end
	return normalize(baseline)
end

-- The parry swing-up for this weapon. THE TIMING CLIP -- its markers are the parry window, so this is
-- the id Server/Combat/Defense/DefenseSystem reads per combatant, not just something the client plays.
function WeaponDefenseAnimations.GetParry(weaponId: string?): string
	return resolve(weaponId, PARRY_FOLDER, DefenseConstants.ParryAnimationId)
end

-- The held-guard loop for this weapon. Client presentation only -- see this file's header on why the
-- two slots are not equally load-bearing despite being authored as a pair.
function WeaponDefenseAnimations.GetBlock(weaponId: string?): string
	return resolve(weaponId, BLOCK_FOLDER, DefenseConstants.BlockHoldAnimationId)
end

-- Visits every non-blank per-weapon override across both slots. Shared by the three sweeps below so
-- they cannot disagree about what counts as authored.
local function eachWeaponOverride(visit: (weaponId: string, folderName: string, resolved: string) -> ()): ()
	local container = weaponsContainer()
	if not container then
		return
	end
	for _, model in container:GetChildren() do
		for _, folderName in { PARRY_FOLDER, BLOCK_FOLDER } do
			local animation = slotAnimation(model, folderName)
			if animation and animation.AnimationId ~= "" then
				local resolved = normalize(animation.AnimationId)
				if resolved ~= "" then
					visit(model.Name, folderName, resolved)
				end
			end
		end
	end
end

-- Every distinct PARRY clip whose markers could ever define a live window -- every weapon's own, plus
-- the shared baseline -- for Server/Combat/Defense/DefenseSystem.Init's boot-time
-- ParryWindows.ValidateAll pass.
--
-- THIS IS WHY THE MODULE HAS A SERVER CALLER AT ALL, and skipping it would be a silent, permanent
-- failure rather than a slow one: ParryWindows.Get NEVER YIELDS (see that module's header -- a block
-- press must resolve on the frame it arrives), so an id whose KeyframeSequence was never prefetched
-- returns nil at press time and the parry simply never arms. Warming only the baseline, as this system
-- did before per-weapon clips existed, would leave every weapon that authors its own PARRY clip
-- strictly WORSE off than one that authors none.
--
-- The BLOCK slot's ids are in neither the sweep nor the return: nothing reads a marker off a block
-- loop, so prefetching one would spend the rate-limited GetKeyframeSequenceAsync budget that the ids
-- which actually gate a mechanic need.
function WeaponDefenseAnimations.GetParryIds(): { string }
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}

	local baseline = normalize(DefenseConstants.ParryAnimationId)
	if baseline ~= "" then
		seen[baseline] = true
		table.insert(ids, baseline)
	end

	eachWeaponOverride(function(_weaponId: string, folderName: string, resolved: string)
		if folderName == PARRY_FOLDER and not seen[resolved] then
			seen[resolved] = true
			table.insert(ids, resolved)
		end
	end)

	return ids
end

-- Every weapon's non-blank defense clips across BOTH slots, deduplicated, for Client/Loading/
-- AssetPreloader.lua's boot-time sweep -- so raising a guard with a freshly-authored weapon for the
-- first time doesn't cold-load its parry mid-press.
--
-- The BASELINE PAIR IS DELIBERATELY NOT HERE: Client/Defense/DefenseClient.lua registers those two on
-- its own manager and AssetPreloader already sweeps them through DefenseClient.GetPreloadInstances().
-- Returning them again would double-count them in the preloader's own progress total for no benefit.
function WeaponDefenseAnimations.GetPreloadIds(): { string }
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}
	eachWeaponOverride(function(_weaponId: string, _folderName: string, resolved: string)
		if not seen[resolved] then
			seen[resolved] = true
			table.insert(ids, resolved)
		end
	end)
	return ids
end

-- Normalized content id -> a readable "WeaponId:Parry"/"WeaponId:Block" label, for AssetPreloader's own
-- failure log -- same diagnostic seam AttackAnimations.GetPreloadLabels and
-- WeaponIdleAnimations.GetPreloadLabels each keep, and for the same reason:
-- "rbxassetid://94883396723007 failed" means a lookup, "Cutlass:Parry failed" means something.
function WeaponDefenseAnimations.GetPreloadLabels(): { [string]: string }
	local labels: { [string]: string } = {}
	eachWeaponOverride(function(weaponId: string, folderName: string, resolved: string)
		local slotLabel = if folderName == PARRY_FOLDER then "Parry" else "Block"
		labels[resolved] = `{weaponId}:{slotLabel}`
	end)
	return labels
end

return WeaponDefenseAnimations
