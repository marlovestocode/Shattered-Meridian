--!strict
--[[
	WeaponIdleAnimations.lua

	Owns: which STANDING-IDLE clip plays while a player is holding a given weapon drawn and not
	otherwise doing anything (not moving, not mid-swing, not blocking). One clip per weapon, read off a
	real Animation instance sitting in that weapon's own Animations/IDLE folder in Workspace.Weapons --
	the same "content lives on the model, not in a Lua table" contract Shared/Combat/WeaponRoster.lua's
	own ATTRIBUTE_NAMES established for Damage/PostureDamage/Reach/Speed, and the same per-weapon-clip
	convention Shared/Attack/AttackAnimations.lua's WEAPON_STAGE_FOLDERS uses for the swing stages
	(M1/M2/M3/HEAVY/FINISHER) -- IDLE is this convention's sixth slot.

	SUPERSEDES A STRING-ATTRIBUTE VERSION OF THIS SAME IDEA (an "AnimIdle" Attribute read straight off
	the weapon model), for the identical reason AttackAnimations.lua's own header gives for its swing
	slots: a weapon now authors its idle pose as a real Animation instance under its own Animations
	folder, full stop, not a text field to paste an id into.

	A SEPARATE, SMALLER FILE FROM AttackAnimations.lua ON PURPOSE, even though the two share a reading
	pattern. AttackAnimations owns one-shot swing clips keyed by MoveId, thrown through Shared/Animation/
	AnimationManager.lua's claim system; this owns exactly one LOOPED full-body clip per weapon, driven
	by Client/FX/CombatAnimator.lua's own dominant-loop evaluator (the same Walking/Running mechanism,
	not a new one -- see that module's own header on SetArmedWeapon). There is no MoveId here, no
	stage, and no shared baseline to fall back to: an unauthored weapon simply has no idle override and
	the character keeps playing Roblox's own default stand-still idle, which is a real and correct
	answer for a weapon nobody has gotten around to posing yet -- exactly as an unattributed weapon
	keeps swinging with AttackAnimations' shared baseline rather than erroring.

	READ DIRECTLY FROM Workspace.Weapons, NOT THROUGH WeaponRoster, for the identical reason
	AttackAnimations.lua gives in its own header: WeaponRoster.Start() only ever runs on the SERVER
	(Server/Main.server.lua), so a client -- which is the only place an idle pose is ever played or
	preloaded -- cannot read this off WeaponRoster's cache. Workspace itself replicates to every client
	regardless, Attributes included, so this module keeps its own copy of the fixed-path lookup, the
	same duplication WeaponRoster.lua, WeaponModelRegistry.lua and AttackAnimations.lua each already
	carry rather than centralising.

	"" MEANS "WIRED, NOT YET AUTHORED", the same convention every other animation table in this
	codebase uses. A missing Animations/IDLE folder, or one with no Animation instance/a still-blank
	AnimationId, resolves to no override and no error -- CombatAnimator falls back to Roblox's own
	default idle for that weapon, silently.

	Does not own: playing anything (Client/FX/CombatAnimator.lua claims the clip), which weapon is
	currently drawn (Server/Combat/Weapon/WeaponInventorySystem.lua, echoed to the client over
	Weapon_InventoryChanged), or a weapon's SWING clips (Shared/Attack/AttackAnimations.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("WeaponIdleAnimations")

local WeaponIdleAnimations = {}

-- The one fixed folder this module reads -- see its header on why this is kept as this module's own
-- copy rather than going through Shared/Combat/WeaponRoster.lua. Same constant, same reasoning, as
-- WeaponRoster.lua's, WeaponModelRegistry.lua's and AttackAnimations.lua's own CONTAINER_NAME.
local WEAPONS_CONTAINER = "Weapons"

-- The subfolder of a weapon's own Animations folder that holds its standing-idle clip -- the sixth
-- slot in Shared/Attack/AttackAnimations.lua's WEAPON_STAGE_FOLDERS convention, kept here rather than
-- imported since that table is that module's own private lookup, not a shared export.
local IDLE_FOLDER = "IDLE"

-- Workspace.Weapons itself, or nil if nobody has made it yet -- mirrors WeaponRoster.findContainer/
-- WeaponModelRegistry.findContainer/AttackAnimations.weaponsContainer exactly, because this is the
-- fourth module reading that one fixed path and none of the four may assume any other has run.
local function weaponsContainer(): Folder?
	local child = Workspace:FindFirstChild(WEAPONS_CONTAINER)
	if not child or not child:IsA("Folder") then
		return nil
	end
	return child :: Folder
end

-- Accepts an asset id in either form an author might reasonably paste and returns the one the engine
-- actually understands. Identical to AttackAnimations.lua's own normalize() -- see that module's
-- header for why a bare digits-only id is worth normalising rather than requiring the "rbxassetid://"
-- prefix by convention alone. Not shared between the two files: each owns a handful of lines of pure
-- string logic with no state, and importing one from the other would be a cross-require for a
-- three-branch function neither is likely to change independently of the other.
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

-- The Animation instance authored in `model`'s own Animations/IDLE folder, or nil when the model has
-- no Animations folder, no IDLE subfolder, or that folder holds no Animation instance. Whichever
-- Animation instance sits directly in the folder is used regardless of its own Name -- one clip per
-- slot, the same convention AttackAnimations.lua's weaponOverride keeps for the swing stages.
local function idleAnimation(model: Instance): Animation?
	local animationsFolder = model:FindFirstChild("Animations")
	if not animationsFolder then
		return nil
	end
	local idleFolder = animationsFolder:FindFirstChild(IDLE_FOLDER)
	if not idleFolder then
		return nil
	end
	return idleFolder:FindFirstChildOfClass("Animation") :: Animation?
end

-- The idle clip authored on `weaponId`'s own model, or "" when it has none. Never nil, never errors on
-- an unknown weapon -- callers (CombatAnimator's resolveArmedIdle) treat "" and "unknown" identically
-- ("no override, fall back to the default idle").
--
-- LOGS THE FULL RESOLUTION CHAIN, not just the final answer -- called infrequently (draw/sheathe/
-- select, never per-frame), so the cost of a full trace every call is nothing, and this is the one
-- place that can actually show whether "no idle clip showing" is a wrong weaponId, a missing
-- Animations folder, a missing IDLE subfolder, no Animation instance in it, or a genuinely blank
-- AnimationId -- five different failures that all look identical from CombatAnimator's own side.
function WeaponIdleAnimations.Get(weaponId: string?): string
	if typeof(weaponId) ~= "string" or weaponId == "" then
		logger:debug("Get: no weaponId given", { weaponId = weaponId })
		return ""
	end
	local container = weaponsContainer()
	if not container then
		logger:debug("Get: Workspace.Weapons folder not found", { weaponId = weaponId })
		return ""
	end
	local model = container:FindFirstChild(weaponId)
	if not model then
		logger:debug("Get: no child of Workspace.Weapons named this weaponId", { weaponId = weaponId })
		return ""
	end
	local animationsFolder = model:FindFirstChild("Animations")
	if not animationsFolder then
		logger:debug("Get: weapon model has no Animations folder", {
			weaponId = weaponId,
			modelPath = model:GetFullName(),
		})
		return ""
	end
	local idleFolder = animationsFolder:FindFirstChild(IDLE_FOLDER)
	if not idleFolder then
		logger:debug("Get: Animations folder has no IDLE subfolder", {
			weaponId = weaponId,
			animationsPath = animationsFolder:GetFullName(),
		})
		return ""
	end
	local animation = idleFolder:FindFirstChildOfClass("Animation") :: Animation?
	if not animation then
		logger:debug("Get: IDLE folder has no Animation instance in it", {
			weaponId = weaponId,
			idleFolderPath = idleFolder:GetFullName(),
		})
		return ""
	end
	if animation.AnimationId == "" then
		logger:debug("Get: Animation instance found, but its AnimationId is blank", {
			weaponId = weaponId,
			animationPath = animation:GetFullName(),
		})
		return ""
	end
	local resolved = normalize(animation.AnimationId)
	logger:debug("Get: resolved", {
		weaponId = weaponId,
		animationPath = animation:GetFullName(),
		rawAnimationId = animation.AnimationId,
		resolved = resolved,
	})
	return resolved
end

-- Every weapon's non-blank idle clip, deduplicated, for Client/Loading/AssetPreloader.lua's boot-time
-- sweep -- so drawing a freshly-authored weapon for the first time doesn't cold-load its idle pose the
-- moment the player stops moving.
function WeaponIdleAnimations.GetPreloadIds(): { string }
	local container = weaponsContainer()
	if not container then
		return {}
	end
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}
	for _, model in container:GetChildren() do
		local animation = idleAnimation(model)
		if animation and animation.AnimationId ~= "" then
			local id = normalize(animation.AnimationId)
			if id ~= "" and not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
	end
	return ids
end

-- Normalized content id -> a readable "WeaponId:Idle" label, for AssetPreloader's own failure log --
-- same diagnostic seam AttackAnimations.GetPreloadLabels keeps for swing clips, and for the same
-- reason: "rbxassetid://82318659005476 failed" means a lookup, "Cutlass:Idle failed" means something.
function WeaponIdleAnimations.GetPreloadLabels(): { [string]: string }
	local container = weaponsContainer()
	if not container then
		return {}
	end
	local labels: { [string]: string } = {}
	for _, model in container:GetChildren() do
		local animation = idleAnimation(model)
		if animation and animation.AnimationId ~= "" then
			local id = normalize(animation.AnimationId)
			if id ~= "" then
				labels[id] = `{model.Name}:Idle`
			end
		end
	end
	return labels
end

return WeaponIdleAnimations
