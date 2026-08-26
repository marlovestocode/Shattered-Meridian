--!strict
--[[
	AttackAnimations.lua

	Owns: which animation clip each hand-authored attack plays. THIS IS THE ONE FILE TO EDIT to give
	the SHARED swings an animation -- paste an asset id next to a stage below and every weapon that
	doesn't override its own clips animates on the very next swing, with no other change anywhere.

	KEYED BY STAGE, NOT BY WEAPON, BY DEFAULT ("Basic:1", not "default:Cutlass:Basic:1"). Every weapon
	in the Workspace.Weapons roster is built from the one CombatConstants.Weapons.Baseline move set
	(see Shared/Combat/WeaponRoster.lua), so an unattributed weapon throws the same five swings and
	wants the same five clips as every other one. A new sword therefore animates the instant it is
	dropped into the roster -- nobody has to remember to come paste five ids under its name first.

	A PER-WEAPON OVERRIDE LIVES ON THE WEAPON, NOT HERE -- this file's own header used to call that a
	"real future want"; WEAPON_STAGE_FOLDERS below is that want, built. A weapon builder drops a real
	Animation instance into their model's own Animations folder in Workspace.Weapons -- Animations/M1,
	Animations/M2, Animations/M3, Animations/HEAVY, Animations/FINISHER, one clip per slot -- the same
	"content lives on the model, not in a Lua table" contract Shared/Combat/WeaponRoster.lua's own
	ATTRIBUTE_NAMES established for Damage/PostureDamage/Reach/Speed, just expressed as a real Animation
	Instance (editable through Studio's own Animation Editor and Properties panel) rather than a string
	Attribute -- a weapon builder is posing a swing, not typing an asset id into a text field, and the
	Animations folder is what a Move Editor-adjacent workflow already organizes those clips into per
	weapon (IDLE/M1/M2/M3/HEAVY/FINISHER -- see Shared/Combat/WeaponIdleAnimations.lua for the IDLE
	slot). Leave a slot's folder empty (or absent) and that stage swings with the shared baseline clip
	below instead, which is a real answer for a reskin -- exactly as leaving the four numeric Attributes
	unset makes a weapon fight like the baseline sword. weaponOverride() is what resolves one slot;
	Get() below tries it before falling back to IDS.

	SUPERSEDES A STRING-ATTRIBUTE VERSION OF THIS SAME IDEA (AnimBasic1/AnimBasic2/AnimBasic3/
	AnimHeavy1/AnimFinisher), which this file used to read directly off the weapon model. That scheme
	is gone, not layered underneath this one: a weapon now authors its swing clips as real Animation
	instances under its own Animations folder, full stop, so there is exactly one place to look rather
	than two competing ones that could silently disagree.

	READ DIRECTLY FROM Workspace.Weapons, NOT THROUGH WeaponRoster. WeaponRoster.Start() only ever runs
	on the SERVER (Server/Main.server.lua), so its entriesById cache does not exist on a client -- and
	this module's GetPreloadIds/GetPreloadLabels are called from Client/Loading/AssetPreloader.lua at
	boot. Workspace itself replicates to every client regardless of that cache, Attributes included, so
	reading Workspace.Weapons.<Id> directly (the same fixed-path convention WeaponRoster.lua and
	WeaponModelRegistry.lua each already keep their own copy of) resolves identically on both sides
	without this Shared module taking a dependency on a server-only singleton.

	WHY THIS FILE EXISTS AT ALL, given the Move Creation System already has an AnimationId field.
	Because that field is only reachable for a CUSTOM move. A "Default" move -- every hand-authored
	attack in Constants.Combat.Weapons, which is the entire live move set -- is a fresh projection built
	by DefaultMoveRegistry on every read, and that projection hardcodes AnimationId = "" and never
	stores one (see its own header: the Move Editor deliberately hides the Animation section for
	Category == "Default"). So a Default move has nowhere to put a clip id, and before this file the
	whole live move set was structurally unable to have an animation. This is that missing shelf.

	THE PRECEDENCE IS: an authored MoveDefinition.AnimationId wins, and this table is the fallback --
	see AttackCatalog.Get, which is the one place the two are combined. A custom move authored in the
	Move Editor with a real clip keeps it; a Default move with nothing to author reaches here.

	"" MEANS "WIRED, NOT YET AUTHORED", the same convention Constants.Combat.AnimationIds and
	Constants.Flight.AnimationIds already use, and it is a first-class value here rather than an
	oversight: every slot below is deliberately blank because THIS REPO DOES NOT GUESS ASSET IDS (see
	Constants.UI.VitalIconIds' own note, and AdminConfig's "never guess or invent a UserId"). A blank id
	resolves to no clip and no error anywhere -- AnimationManager refuses the claim silently, and
	Client/Combat/AttackInputClient.lua returns before even making it. The swing still happens, still
	hits, still deals damage; it just is not animated yet.

	SO: to animate the game's attacks, upload the clips and fill in the strings below. Nothing else has
	to change -- not the client, not the server, not the catalogue, not the preloader (which sweeps
	GetPreloadIds below, so an id pasted here is warm before the first swing rather than hitching on it).

	EITHER FORM OF ID WORKS -- a bare "82318659005476" or a full "rbxassetid://82318659005476". The
	engine only understands the second, but the first is what Roblox's own asset page, Toolbox and
	Creator Dashboard all display, so it is what actually gets pasted. See WeaponAssets.NormalizeAssetId() below for why
	that mismatch is worth a helper rather than a rule an author has to remember: a bare id resolves to
	nothing, silently, in a file that looks correctly filled in.

	ONE CLIP PER MOVE, not a timeline. The Move Creation System's richer MoveDefinition.Animations list
	(AnimationTimeline.Clip, with per-clip start/stop/speed/fade/blend control) is not reached from here
	-- it is a custom-move authoring feature, and its runtime playback path went with the combat
	teardown. A single clip per attack is what the rebuilt client actually plays today; when timeline
	playback comes back, this file is the fallback it falls back TO, not something it replaces.

	Does not own: playing anything (Client/Combat/AttackInputClient.lua claims the clip through
	Shared/Animation/AnimationManager.lua), which move a press throws (SwingSequencer), or the timing
	the clip should sync to (AttackTypes.AttackStartedPayload carries the server's real windup/active/
	recovery for exactly that). Also does not own a weapon's STANDING idle -- that is a full-body loop
	rather than a one-shot swing, and lives in Shared/Combat/WeaponIdleAnimations.lua /
	Client/FX/CombatAnimator.lua instead; see those modules' own headers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)

local logger = Logger.scope("AttackAnimations")

local AttackAnimations = {}

-- The one fixed folder every per-weapon override is read from -- see this file's header on why this
-- module keeps its own copy of the path rather than going through Shared/Combat/WeaponRoster.lua.
-- Same constant, same reasoning, as that module's and WeaponModelRegistry.lua's own CONTAINER_NAME.

-- Stage key -> the subfolder of a weapon's own Animations folder that holds that stage's clip. Only
-- the five weapon-stage keys have an entry -- the standalone attacks (DashPunch, DashHit, AirSlam)
-- have no weapon to hang an override off, so they are only ever authored through IDS below, exactly
-- as before this table existed.
local WEAPON_STAGE_FOLDERS: { [string]: string } = {
	["Basic:1"] = "M1",
	["Basic:2"] = "M2",
	["Basic:3"] = "M3",
	["Heavy:1"] = "HEAVY",
	["Finisher"] = "FINISHER",
}

-- MoveId -> animation asset id. Keys are DefaultMoveRegistry's own synthetic ids, which is the same
-- scheme SwingSequencer builds when it resolves a press -- see that module for how one is formed.
--
-- An id not listed here is not an error: Get returns "" for anything unknown, which is exactly what an
-- unauthored slot resolves to anyway. Add a key when there is a clip to put in it.
local IDS: { [string]: string } = {
	-- Weapon stages, keyed by STAGE ALONE -- see this file's header on why the weapon is not part of
	-- the key.
	-- The light string. Three stages, thrown in order, wrapping back to 1 -- so these three read as a
	-- sequence and are worth authoring as one: a clip that ends where the next begins.
	["Basic:1"] = "104588315151150",
	["Basic:2"] = "78226937952673",
	["Basic:3"] = "106982083848684",
	-- The heavy swing. A single stage, much longer windup (0.6s) -- a clip here has real room to
	-- telegraph, which is the whole point of a heavy in this game's defence model: the windup IS the
	-- tell a defender parries off.
	["Heavy:1"] = "83363364108102",
	-- Thrown only when a full Basic string LANDED (AttackConstants.Finisher.MinComboStage) -- the
	-- payoff swing, and the one most worth a distinctive clip.
	["Finisher"] = "138196103225171",

	-- Standalone attacks --------------------------------------------------------------------------
	-- Catalogued and throwable through the hotbar, but not part of either string. Listed so they are
	-- authorable from the same place rather than being the one set that needs a different mechanism.
	-- Keyed by their full MoveId because they have no weapon in them to strip.
	["default:DashPunch"] = "",
	["default:DashHit"] = "",
	["default:AirSlam"] = "",
}

-- Splits a weapon-stage MoveId into the weapon that threw it and the stage key IDS/
-- WEAPON_STAGE_ATTRIBUTES both use, so "default:Cutlass:Basic:1" yields ("Cutlass", "Basic:1"). The
-- weapon is nil for anything that is not a weapon-stage id (the standalones, a custom move) -- those
-- have no model to read an override from, so callers skip straight to the shared table for them, the
-- same as before this split existed.
local function splitWeaponStage(moveId: string): (string?, string)
	local weaponId, stage = string.match(moveId, "^default:([^:]+):(.+)$")
	if weaponId and stage then
		return weaponId, stage
	end
	return nil, moveId
end

-- Workspace.Weapons itself, or nil if nobody has made it yet -- mirrors WeaponRoster.findContainer/
-- WeaponModelRegistry.findContainer exactly (down to the warn-and-ignore on a same-named non-Folder),
-- because this is the third module reading that one fixed path and none of the three may assume
-- either of the others has run.

-- The Animation instance authored for `stage` on `weaponId`'s own model, or nil when the weapon
-- doesn't exist, the stage has no folder slot, the weapon has no Animations folder, that slot's own
-- folder is missing, or it holds no Animation instance (or one with a still-blank AnimationId).
-- Whichever Animation instance sits directly in the slot folder is used regardless of its own Name --
-- one clip per slot, the same convention IDS below keeps for the shared baseline.
-- LOGS THE FULL RESOLUTION CHAIN, not just the final answer -- the same reasoning Shared/Combat/
-- WeaponIdleAnimations.lua's own Get() gives for doing this: "no override" looks identical from the
-- caller's side whether the weapon doesn't exist, the model has no Animations folder, the stage's own
-- subfolder is missing, it holds no Animation instance, or the Animation instance is there with a
-- still-blank AnimationId -- five different authoring states that need five different fixes.
local function weaponOverride(weaponId: string, stage: string): string?
	local folderName = WEAPON_STAGE_FOLDERS[stage]
	if not folderName then
		return nil
	end
	-- The forty-line walk and its six-step trace live in Shared/Combat/WeaponAssets.ResolveAnimation
	-- now -- Defense/WeaponDefenseAnimations.lua held the same one, differing only in the field name
	-- it logged the slot under. What stays here is the one thing that IS this module's: which folder
	-- name an attack STAGE maps to.
	return WeaponAssets.ResolveAnimation(logger, weaponId, folderName)
end

AttackAnimations.Ids = IDS

-- Accepts an asset id in either form an author might reasonably paste and returns the one the engine
-- actually understands.
--
-- WHY THIS IS NOT PEDANTRY. Roblox's own asset page, the Toolbox and the Creator Dashboard all show a
-- bare number, so a bare number is what gets copied -- but AnimationManager.resolveAssetId accepts a
-- registry key or a string matching "^rbxassetid://" and treats EVERYTHING ELSE as an unauthored slot.
-- A bare id therefore resolves to nil, the claim is refused, and the swing silently plays no
-- animation -- with no error, no warning, and a config file that looks correctly filled in. That is
-- the worst possible failure for the one file whose whole promise is "paste an id here and it works",
-- so this normalises rather than making the promise conditional on knowing the prefix.
--
-- Left as-is if the prefix is already there, so both forms are equally correct to author.

-- The clip for `moveId`, or "" when it has none. Never nil, never errors on an unknown id -- callers
-- treat "" and "unknown" identically ("do not claim a clip"), so distinguishing them would only give
-- every call site a second case to get wrong.
--
-- WEAPON OVERRIDE FIRST, SHARED BASELINE SECOND -- the same precedence AttackCatalog.Get itself keeps
-- one level up (an authored MoveDefinition.AnimationId beats this whole file). A weapon that hasn't
-- set its own Attribute for this stage falls straight through to IDS, so an unattributed weapon keeps
-- animating exactly as it always has.
function AttackAnimations.Get(moveId: string): string
	if typeof(moveId) ~= "string" then
		return ""
	end
	local weaponId, stage = splitWeaponStage(moveId)
	if weaponId then
		local override = weaponOverride(weaponId, stage)
		if override then
			return WeaponAssets.NormalizeAssetId(override)
		end
	end
	return WeaponAssets.NormalizeAssetId(IDS[stage] or "")
end

-- Every weapon's non-blank override, as (weaponId, stage, rawId) triples -- the one walk every weapon
-- override sweep needs, shared by GetPreloadIds and GetPreloadLabels so neither re-derives it. Reads
-- Workspace.Weapons directly, same as weaponOverride() above and for the same reason (see this file's
-- header on why this module cannot go through WeaponRoster's server-only cache).
local function eachWeaponOverride(visit: (weaponId: string, stage: string, raw: string) -> ()): ()
	local container = WeaponAssets.Container(logger)
	if not container then
		return
	end
	for _, model in container:GetChildren() do
		local animationsFolder = model:FindFirstChild("Animations")
		if animationsFolder then
			for stage, folderName in WEAPON_STAGE_FOLDERS do
				local stageFolder = animationsFolder:FindFirstChild(folderName)
				if stageFolder then
					local animation = stageFolder:FindFirstChildOfClass("Animation") :: Animation?
					if animation and animation.AnimationId ~= "" then
						visit(model.Name, stage, animation.AnimationId)
					end
				end
			end
		end
	end
end

-- Every non-blank id, deduplicated, for Client/Loading/AssetPreloader.lua's boot-time sweep. Covers
-- both the shared baseline (IDS) and every weapon's own per-stage override, so a clip pasted into
-- either place is warm before the first swing that could reach it rather than cold-loading mid-fight.
--
-- Returns raw content ids rather than Animation Instances, the same contract
-- DefenseClient.GetPreloadInstances and ParkourAnimator's own provider already use -- AnimationManager
-- pools its template Instances internally and does not hand them out.
--
-- Deduplicated because sharing one clip across several stages is a completely reasonable thing to do
-- while authoring (and is exactly what Constants.Flight.AnimationIds does across its own six slots),
-- and preloading the same id six times is six times the work for one asset.
function AttackAnimations.GetPreloadIds(): { string }
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}
	local function addId(raw: string)
		-- Normalised here too, not just in Get: ContentProvider is as literal about the prefix as the
		-- animation loader is, so preloading a bare id would warm nothing while the real one still
		-- cold-loads on the first swing.
		local id = WeaponAssets.NormalizeAssetId(raw)
		if id ~= "" and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	for _, raw in IDS do
		addId(raw)
	end
	eachWeaponOverride(function(_weaponId, _stage, raw)
		addId(raw)
	end)
	return ids
end

-- Normalized content id -> a readable label, for AssetPreloader's own failure log: "MoveId
-- FrontLight1 failed" (or "Cutlass:Basic:1 failed" for an override) means something to a reader,
-- "rbxassetid://82318659005476 failed" means a lookup. IDS is otherwise private (every other caller
-- goes through Get/GetPreloadIds), so this is the one deliberate seam for exactly that diagnostic
-- purpose -- not a general-purpose export.
function AttackAnimations.GetPreloadLabels(): { [string]: string }
	local labels: { [string]: string } = {}
	for moveId, raw in IDS do
		local id = WeaponAssets.NormalizeAssetId(raw)
		if id ~= "" then
			labels[id] = moveId
		end
	end
	eachWeaponOverride(function(weaponId, stage, raw)
		local id = WeaponAssets.NormalizeAssetId(raw)
		if id ~= "" then
			labels[id] = `{weaponId}:{stage}`
		end
	end)
	return labels
end

return AttackAnimations
