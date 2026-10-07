--!strict
--[[
	WeaponSounds.lua

	Owns: resolving a weapon's own authored SOUND EFFECTS off its model in Workspace.Weapons -- the
	Sound instances a weapon builder drops into their model's own SFX folder (SFX/Swing, SFX/Block,
	SFX/Parry, SFX/Equip, SFX/Sheathe, one Sound per slot) -- into the SoundTypes.SoundDefinition shape
	Client/FX/SoundManager.lua registers and plays.

	THE AUDIO HALF OF A CONVENTION THAT ALREADY EXISTS FOR CLIPS. Shared/Attack/AttackAnimations.lua's
	WEAPON_STAGE_FOLDERS (Animations/M1..FINISHER) and Shared/Combat/WeaponIdleAnimations.lua's own
	Animations/IDLE are the same idea for animation: "content lives on the model, not in a Lua table,"
	the contract Shared/Combat/WeaponRoster.lua's ATTRIBUTE_NAMES established for Damage/PostureDamage/
	Reach/Speed. A sword's whoosh, its clang and its draw are content in exactly the same sense -- a
	weapon builder is picking a sound for THEIR sword, not pasting an asset id into a shared Lua table
	that every other weapon also reads. This module is that folder, read.

	NOT A REPLACEMENT FOR CombatConstants.Sound. That table stays exactly what it was: the SHARED,
	weapon-agnostic layer -- the unarmed swing whoosh, and the per-outcome impact stingers that answer
	"what kind of hit was that" regardless of what landed it. This module is the per-weapon OVERRIDE
	layer on top of it, the same precedence Shared/Attack/AttackAnimations.lua already runs (weapon
	override first, shared baseline second). A weapon with no SFX folder, an empty slot, or a Sound with
	a blank SoundId simply has no override and falls back to the shared sound -- which is a real answer
	for a reskin, not a gap. Client/FX/CombatAudio.lua is where the two layers actually meet; see its
	own header for which moments consult which.

	READ DIRECTLY FROM Workspace.Weapons, NOT THROUGH WeaponRoster, for the identical reason
	AttackAnimations.lua and WeaponIdleAnimations.lua each give in their own headers: WeaponRoster.Start()
	only ever runs on the SERVER, and every reader of this module is a client. Workspace replicates to
	every client regardless, so this module keeps its own copy of the fixed-path lookup -- the same
	duplication WeaponRoster.lua, WeaponModelRegistry.lua, AttackAnimations.lua and
	WeaponIdleAnimations.lua each already carry rather than centralising.

	PARSES THE ID RATHER THAN TRUSTING IT, which is the one thing this module does that its animation
	siblings only half do. A Sound instance's SoundId reaches this codebase through several honest
	routes that produce three different strings for the same asset: a Toolbox drag gives
	"rbxassetid://123", a hand-typed id from the Creator Dashboard gives a bare "123", and an older
	imported model gives "http://www.roblox.com/asset/?id=123". Only the first resolves. The other two
	are perfectly good strings that no linter, no type and no test objects to, and Roblox's ONLY signal
	for them is a Studio console line that is trivially lost under a boot log (see SoundManager.Register's
	own warn on exactly this, which has already cost one playtest) -- so WeaponAssets.NormalizeAssetId() below converts all
	three rather than making a weapon builder remember which one the engine wants.

	TOLERANT OF FOLDER-NAME CASE, deliberately, and unlike the animation lookups. The animation slots
	are UPPERCASE by convention (M1/HEAVY/IDLE) while the sound slots read naturally as words
	(Swing/Block/Parry) -- one weapon model carrying both conventions side by side is exactly the setup
	where "SWING" or "swing" gets typed into the wrong one. An exact match is tried first and is always
	what a correctly-named folder hits; the case-insensitive sweep is a fallback that costs one
	GetChildren pass on the miss path only. Sheathe/Sheath are accepted as the same slot for the same
	reason: both spellings are correct English and a builder should not have to guess which one this
	repo picked.

	Does not own: playing anything, pooling, or registration (Client/FX/SoundManager.lua owns the Sound
	instances; Client/FX/CombatAudio.lua owns which name maps to which moment), WHEN a swing or a block
	happens (the combat stack decides that), or which weapon a character is holding
	(Server/Combat/Weapon/WeaponInventorySystem.lua, echoed to clients over Weapon_InventoryChanged and
	stamped on the equipped Tool as WeaponConstants.Visual.WeaponIdAttribute).

	2D, LIKE EVERY OTHER SOUND IN THIS GAME. SoundManager parents its instances to SoundService, so a
	weapon's authored RollOffMode/RollOffMaxDistance/EmitterSize are NOT carried over -- only SoundId
	and Volume are read. Positional weapon audio is a SoundManager capability that does not exist yet
	(see its own header's closing note); when it does, this module gains fields rather than changing
	shape.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundTypes = require(ReplicatedStorage.Shared.SoundTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)

local logger = Logger.scope("WeaponSounds")

local WeaponSounds = {}

export type SoundDefinition = SoundTypes.SoundDefinition

-- The one fixed folder this module reads -- see its header on why this is kept as this module's own
-- copy rather than going through Shared/Combat/WeaponRoster.lua. Same constant, same reasoning, as
-- WeaponRoster.lua's, WeaponModelRegistry.lua's, AttackAnimations.lua's and WeaponIdleAnimations.lua's
-- own CONTAINER_NAME.

-- The weapon model's own sound folder, sibling to the Animations folder the two clip modules read.
local SFX_FOLDER = "SFX"

-- Every slot a weapon may author, and the canonical folder name each one lives in. Exported (frozen)
-- rather than kept private, because Client/FX/CombatAudio.lua names these at its call sites and a
-- string literal typed twice is a slot that silently resolves to nothing on one of them.
WeaponSounds.Slots = table.freeze({
	-- The weapon's own whoosh, overriding CombatConstants.Sound.Swing's shared one.
	Swing = "Swing",
	-- The defender's weapon catching a swing on guard (DefenseTypes.OutcomeKind "Blocked").
	Block = "Block",
	-- The defender's weapon turning a swing aside (OutcomeKind "Parried").
	Parry = "Parry",
	-- Drawing the weapon (Weapon_InventoryChanged going Drawn = true).
	Equip = "Equip",
	-- Putting it away (Drawn going back to false).
	Sheathe = "Sheathe",
})

export type Slot = "Swing" | "Block" | "Parry" | "Equip" | "Sheathe"

-- Alternate folder names accepted for a slot, canonical first. Only genuine spelling forks live here
-- -- CASE is handled generically by findChild below rather than by listing every capitalisation, and
-- nothing gets an invented synonym ("Slash", "Clang") that no weapon in this repo actually uses.
local SLOT_ALIASES: { [string]: { string } } = {
	Swing = { "Swing" },
	Block = { "Block" },
	Parry = { "Parry" },
	Equip = { "Equip" },
	-- Both spellings are correct English and both get typed. Neither is worth a support question.
	Sheathe = { "Sheathe", "Sheath" },
}

-- Exact match first (the hit path for a correctly-named folder, one FindFirstChild), then a single
-- case-insensitive sweep over the children as a fallback -- see this file's header on why sound slots
-- get that tolerance where the animation slots do not.
local function findChild(parent: Instance, names: { string }): Instance?
	for _, name in names do
		local exact = parent:FindFirstChild(name)
		if exact then
			return exact
		end
	end
	for _, child in parent:GetChildren() do
		local lowered = string.lower(child.Name)
		for _, name in names do
			if lowered == string.lower(name) then
				return child
			end
		end
	end
	return nil
end

-- Accepts an asset id in any of the three forms a SoundId honestly arrives in and returns the one the
-- engine actually resolves -- see this file's header for why all three exist and why only one works.
-- Deliberately NOT shared with AttackAnimations.lua/WeaponIdleAnimations.lua's own WeaponAssets.NormalizeAssetId(): those
-- two handle the two ANIMATION forms, this one also has to handle the legacy asset-URL form that only
-- ever shows up on Sounds pulled out of older imported models. Anything it does not recognise is
-- returned untouched, so a future content-id scheme degrades to "passed straight through", never to "".

-- Workspace.Weapons itself, or nil if nobody has made it yet -- mirrors WeaponRoster.findContainer/
-- WeaponModelRegistry.findContainer/AttackAnimations.weaponsContainer/WeaponIdleAnimations.weaponsContainer
-- exactly, because this is the fifth module reading that one fixed path and none of the five may assume
-- any other has run.

-- Last failure reason logged per "weaponId|slot", so the resolution chain stays traceable WITHOUT
-- being re-logged on every call.
--
-- WeaponIdleAnimations.Get logs its full chain unconditionally and says so in its own header -- it can
-- afford to, because an idle is resolved on draw/sheathe/select and never per-frame. A SWING sound is
-- resolved several times a second in a real fight, and Logger.emit plus the Live Console's capture
-- ring are two of the biggest client allocation sources in this codebase (see the client perf audit),
-- so an unconditional chain here would turn a diagnostic into a per-swing garbage source. Keyed by
-- reason as well as slot so a builder who FIXES one failure and hits the next one still sees the next
-- one -- the log is silenced for a repeated identical failure, not for the slot.
local lastLoggedReason: { [string]: string } = {}

local function logMiss(weaponId: string, slot: string, reason: string, details: { [string]: any }): ()
	local key = string.format("%s|%s", weaponId, slot)
	if lastLoggedReason[key] == reason then
		return
	end
	lastLoggedReason[key] = reason
	logger:debug(reason, details)
end

-- The Sound instance authored for `slot` on `model`, or nil when the model has no SFX folder, no
-- folder for that slot, or that folder holds no Sound. Whichever Sound sits directly in the slot
-- folder is used regardless of its own Name ("CutlassSwing", "Swing", "swoosh_02" all work) -- one
-- sound per slot, the same convention the animation slots keep for their one clip.
local function slotSound(model: Instance, slot: string): Sound?
	local aliases = SLOT_ALIASES[slot]
	if not aliases then
		return nil
	end
	local sfxFolder = findChild(model, { SFX_FOLDER })
	if not sfxFolder then
		return nil
	end
	local slotFolder = findChild(sfxFolder, aliases)
	if not slotFolder then
		return nil
	end
	return slotFolder:FindFirstChildOfClass("Sound")
end

-- The definition authored for `weaponId`'s own `slot`, or nil when it has none. nil (not a blank
-- definition) is the "no override" answer callers branch on -- Client/FX/CombatAudio.lua falls back to
-- CombatConstants.Sound's shared registration on it, exactly as an unposed weapon falls back to
-- AttackAnimations' shared baseline clip.
--
-- SoundId is normalized (see normalize above); Volume is taken as the weapon builder authored it on
-- the Sound instance itself, which is the whole point of putting the Sound on the model rather than an
-- id in a table -- they can hear it and set the level in Studio, with no code change.
function WeaponSounds.Get(weaponId: string?, slot: string): SoundDefinition?
	if typeof(weaponId) ~= "string" or weaponId == "" then
		return nil
	end
	if not SLOT_ALIASES[slot] then
		-- A caller naming a slot that does not exist is a typo at the call site, not a content gap, so
		-- this one warns rather than taking the quiet logMiss path every content gap below takes.
		logger:warn("Get: unknown slot requested", { weaponId = weaponId, slot = slot })
		return nil
	end

	local container = WeaponAssets.Container(logger)
	if not container then
		logMiss(weaponId, slot, "Get: Workspace.Weapons folder not found", { weaponId = weaponId, slot = slot })
		return nil
	end
	local model = container:FindFirstChild(weaponId)
	if not model then
		logMiss(weaponId, slot, "Get: no child of Workspace.Weapons named this weaponId", {
			weaponId = weaponId,
			slot = slot,
		})
		return nil
	end

	local sound = slotSound(model, slot)
	if not sound then
		logMiss(weaponId, slot, "Get: weapon has no Sound authored in this slot", {
			weaponId = weaponId,
			slot = slot,
			modelPath = model:GetFullName(),
		})
		return nil
	end
	if sound.SoundId == "" then
		logMiss(weaponId, slot, "Get: Sound instance found, but its SoundId is blank", {
			weaponId = weaponId,
			slot = slot,
			soundPath = sound:GetFullName(),
		})
		return nil
	end

	local resolved = WeaponAssets.NormalizeAssetId(sound.SoundId)
	if resolved ~= sound.SoundId then
		-- Worth saying out loud once: the weapon works, but the id AS AUTHORED would not have resolved
		-- on its own, and the next sound pasted in the same form somewhere this module does not read
		-- will be silently dead. Same failure SoundManager.Register warns about, caught one layer
		-- earlier and already fixed.
		logMiss(weaponId, slot, "Get: SoundId normalized to a content URL", {
			weaponId = weaponId,
			slot = slot,
			rawSoundId = sound.SoundId,
			resolved = resolved,
		})
	end

	return { SoundId = resolved, Volume = sound.Volume }
end

-- Every weapon's non-blank sound id across every slot, deduplicated, for
-- Client/Loading/AssetPreloader.lua's boot-time sweep -- so the first swing/block/draw of a session
-- doesn't pay CDN streaming latency mid-fight. Raw id strings rather than Sound instances, the same
-- shape WeaponIdleAnimations.GetPreloadIds hands back and for the same reason:
-- Client/FX/CombatAudio.lua registers these lazily as weapons are actually drawn, so there is no fixed
-- pool of instances for the preloader to be handed.
function WeaponSounds.GetPreloadIds(): { string }
	local container = WeaponAssets.Container(logger)
	if not container then
		return {}
	end
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}
	for _, model in container:GetChildren() do
		for _, slot in WeaponSounds.Slots do
			local sound = slotSound(model, slot)
			if sound and sound.SoundId ~= "" then
				local id = WeaponAssets.NormalizeAssetId(sound.SoundId)
				if id ~= "" and not seen[id] then
					seen[id] = true
					table.insert(ids, id)
				end
			end
		end
	end
	return ids
end

-- Normalized content id -> a readable "WeaponId:Slot" label, for AssetPreloader's own failure log --
-- same diagnostic seam AttackAnimations.GetPreloadLabels/WeaponIdleAnimations.GetPreloadLabels keep,
-- and for the same reason: "rbxassetid://123533685284641 failed" means a lookup, "Cutlass:Parry failed"
-- means something.
function WeaponSounds.GetPreloadLabels(): { [string]: string }
	local container = WeaponAssets.Container(logger)
	if not container then
		return {}
	end
	local labels: { [string]: string } = {}
	for _, model in container:GetChildren() do
		for _, slot in WeaponSounds.Slots do
			local sound = slotSound(model, slot)
			if sound and sound.SoundId ~= "" then
				local id = WeaponAssets.NormalizeAssetId(sound.SoundId)
				if id ~= "" then
					labels[id] = string.format("%s:%s", model.Name, slot)
				end
			end
		end
	end
	return labels
end

return WeaponSounds
