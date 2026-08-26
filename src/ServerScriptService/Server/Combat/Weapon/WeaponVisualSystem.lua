--!strict
--[[
	WeaponVisualSystem.lua

	Owns: making a combatant's equipped weapon (AttackRequestSystem/SwingSequencer's own
	one-weapon-at-a-time concept -- an id from the Workspace.Weapons roster) VISIBLE, attached to their
	right hand, and kept there. Before this System existed, "equipped weapon" was purely a move-set
	selector: SwingSequencer.GetWeapon(model) decided which Basic/Heavy/Finisher stage array a press
	read from, and nothing ever drew anything in the character's hand for it -- a player fighting with
	sword moves had empty fists the whole time. This System closes exactly that gap and nothing else.

	A SIBLING OF THE ATTACK LAYER, NOT A FIFTH LAYER STACKED ON TOP -- the same posture GrabSystem's own
	header establishes for itself. It subscribes to AttackRequestSystem.OnWeaponChanged (a signal built
	for exactly this, mirroring DamageSystem.OnApplied's own contract: returns a disconnect function,
	fires from inside a pcall so a consumer erroring cannot unwind into the Attack layer's own
	Heartbeat) and is READ BY NOTHING -- unlike GrabSystem, this System is purely cosmetic and gates no
	combat decision, so AttackRequestSystem has no seam reaching back into it at all.

	FIRES ON EVERY ACCEPTED SWAP AND ON EVERY CHARACTER BIND (spawn/respawn), not just swaps --
	AttackRequestSystem.OnWeaponChanged's own header explains why: a fresh life's record starts on the
	roster's first weapon (WeaponRoster.Default), and bindCharacter reports that starting weapon
	through the identical signal a later swap uses, so this System never needs a separate "what does a
	new character start holding" special case.

	WHY A REAL Tool, NOT A HAND-ROLLED Motor6D. Server/Combat/HitboxEngine/HitboxEngine.lua's
	resolveAttachmentPart ALREADY expects a future "Weapon" hitbox attachment point to resolve through
	`model:FindFirstChildOfClass("Tool")` and that Tool's own Handle -- see its own comment. Building on
	a real Tool means that seam is satisfied for free, the moment a Basic/Heavy stage ever wants to
	anchor its hitbox at the weapon instead of the hand, without this System or that one changing.
	Humanoid:EquipTool does the actual grip creation (R15 "RightGrip" to Handle, R6's equivalent) --
	the platform's own well-tested mechanism, not reinvented here. CanBeDropped is set false so nothing
	(a stray Backspace, a native drop flow this game's UI never exposes anyway) can separate a player
	from their weapon outside a real swap.

	BUT THAT GRIP IS A Weld, NOT A Motor6D, AND THIS SYSTEM REPLACES IT -- see MotorizeGrip below. This
	header claimed the opposite for several revisions ("EquipTool does the actual Motor6D grip
	creation"), and that one wrong word is why a rigged weapon looked like it should work: Roblox
	creates a plain Weld named RightGrip, an Animator drives Motor6D and nothing else, so no keyframe
	authored against the weapon could ever reach it.

	NO REGISTRY OF ITS OWN, same reasoning DamageSystem/GrabSystem's own headers give for theirs: the
	one thing this System remembers (which Tool a character is currently wearing) is a literal child of
	that character (named by CURRENT_TOOL_NAME below) and is destroyed automatically when the character
	is, so there is nothing to reclaim on PlayerRemoving/CharacterRemoving that Roblox does not already
	do for free.

	Does not own: which weapon a combatant is fighting with (SwingSequencer, read through
	AttackRequestSystem's signal), what that weapon looks like (Shared/Combat/WeaponModels.lua), which
	template a weapon id resolves to (Shared/Combat/WeaponModelRegistry.lua -- started from this
	System's own Init, same as everything else here, since nothing else in the boot chain needs it
	running before a weapon is first equipped), or hitbox contact/reach (HitboxEngine -- this System's Tool is
	cosmetic only until/unless a move is authored with a "Weapon" AttachmentPoint).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local WeaponModelRegistry = require(ReplicatedStorage.Shared.Combat.WeaponModelRegistry)
local WeaponModels = require(ReplicatedStorage.Shared.Combat.WeaponModels)

local AttackRequestSystem = require(script.Parent.Parent.Attack.AttackRequestSystem)

type WeaponId = Types.WeaponId

local logger = Logger.scope("WeaponVisualSystem")

local WeaponVisualSystem = {}

local started = false
local weaponChangedDisconnect: (() -> ())? = nil

-- The one weapon-visual Tool a character may be wearing at a time, found/replaced by name rather than
-- tracked in a table keyed by Model -- the Tool's own lifetime is already tied to the character's (it
-- is a descendant, and dies when the character does), so a side table would only be one more thing to
-- reclaim on CharacterRemoving for no benefit over FindFirstChild.
--
-- THE NAME AND THE ATTRIBUTE NOW LIVE IN Shared/Combat/WeaponConstants.lua, not here, because this
-- Tool turned out to be the one replicated statement of "which weapon is this character holding" that
-- a CLIENT can read about another player -- Client/FX/CombatAudio.lua needs exactly that to play the
-- right weapon's block/parry sound. A private copy on each side would be two string literals that
-- silently stop matching the day one of them is renamed, with nothing failing except the audio.
local CURRENT_TOOL_NAME = WeaponConstants.Visual.ToolName
local WEAPON_ID_ATTRIBUTE = WeaponConstants.Visual.WeaponIdAttribute

-- The joint Roblox's own Tool grip creates, and the name MotorizeGrip keeps when it swaps the class
-- underneath it. Same name on R15 and R6 -- only the arm part it hangs off differs, and this System
-- never needs to know which, since it finds the joint by what it CONNECTS rather than by where it sits.
local GRIP_JOINT_NAME = "RightGrip"

-- Swaps the Weld Humanoid:EquipTool just made for a Motor6D with the identical Part0/Part1/C0/C1.
--
-- PUBLIC ONLY SO A SPEC CAN DRIVE IT, the same split EquipVisual/Attach already carry and for the
-- identical reason: this is the real production step, not a copy of one, so a case driving it is
-- exercising the real path. It needs that seam more than they do -- the joint it replaces is built by
-- Humanoid:EquipTool against a REAL rig's grip attachment, and the headless test harness builds none
-- at all (verified, not assumed: a dummy with a Right Arm part still comes back with no RightGrip),
-- so going through EquipVisual would leave every assertion here vacuously true. EquipVisual remains
-- the only production caller.
--
-- WHY: AN Animator DRIVES Motor6D AND NOTHING ELSE. A Weld (and a WeldConstraint) is a fixed
-- constraint with no Transform for an animation to write, so a weapon rigged in Blender -- a blade
-- that turns in the hand across a swing, a segmented chain, anything with real articulation -- is
-- rigid in play no matter how the clip was authored. The track still loads, still plays, still reports
-- the correct Length and WeightCurrent, and the weapon still simply inherits the hand's motion. Every
-- diagnostic says it is working. This is the same class of invisible failure the default Animate
-- script's toolnone pose causes one layer up (see Client/FX/CombatAnimator.lua's own
-- suppressDefaultToolAnimations) and it needs the same kind of fix: at the source, once, for every
-- weapon, rather than as something a weapon author has to know to ask for.
--
-- UNCONDITIONAL, NOT GATED BEHIND AN "IsRigged" ATTRIBUTE. A Motor6D with nothing animating it holds
-- exactly the pose its C0/C1 describe -- which are copied verbatim off the Weld here -- so a static
-- weapon is bit-for-bit unchanged by this, and a rigged one starts working without anybody
-- remembering to flag it. A flag would only be a fifth thing to get wrong, and its failure mode
-- (forgot to set it) is the exact silent no-op this function exists to eliminate.
--
-- REPLACED RATHER THAN ADDED ALONGSIDE. Leaving the Weld in place next to the new Motor6D would
-- reintroduce the whole problem -- two rigid joints across the same part pair, with the Weld free to
-- win -- so the Motor6D is parented first (never a frame with the Handle attached by nothing, which
-- would let a massless blade drift off the hand) and the Weld destroyed immediately after, both inside
-- the same resumption so physics cannot step between them.
--
-- THE REST POSE IS STILL THE GRIP ATTRIBUTES' JOB, not this function's. C0/C1 come straight off the
-- Weld, which Roblox built from the rig's own grip attachment and Tool.Grip -- itself composed from
-- WeaponModelRegistry's WeaponGripPosition/WeaponGripRotation Attributes. An animation writes
-- Motor6D.Transform ON TOP of that rest pose, so a clip authored against a different rest offset than
-- the one those Attributes produce plays correctly but visibly offset. That is tuned on the model in
-- Studio, where every other grip question already is, not here.
function WeaponVisualSystem.MotorizeGrip(character: Model, tool: Tool): ()
	local handleChild = tool:FindFirstChild("Handle")
	if not (handleChild and handleChild:IsA("BasePart")) then
		return
	end
	local handle = handleChild :: BasePart

	-- Found by Part1 rather than by path: the grip hangs off RightHand on R15 and "Right Arm" on R6,
	-- and matching on what it actually joins is both narrower than a name-only search (a character
	-- could carry another same-named joint) and indifferent to which rig this player arrived on.
	local grip: Weld? = nil
	for _, descendant in character:GetDescendants() do
		if
			descendant:IsA("Weld")
			and descendant.Name == GRIP_JOINT_NAME
			and (descendant :: Weld).Part1 == handle
			-- NEVER a joint living INSIDE the weapon. The engine parents its grip to the arm, which is
			-- outside the Tool -- so anything matching from within the weapon's own hierarchy is the
			-- author's, not Roblox's. A weapon that ships its own Weld named RightGrip onto its Handle
			-- (not hypothetical -- a real rig on this project carried that exact name before being
			-- renamed) would otherwise be converted INSTEAD of the real grip, leaving the actual grip a
			-- Weld and the weapon just as unanimatable as before, with the fix apparently applied.
			-- Class alone does not cover it: Motor6D is a sibling of Weld under JointInstance, not a
			-- subclass, so an author's Motor6D is already excluded -- but their Weld is not.
			and not descendant:IsDescendantOf(tool)
		then
			grip = descendant :: Weld
			break
		end
	end
	if not grip then
		-- Not an error, and deliberately not a warn: a dummy rig with no arm part (every combat spec's
		-- makeDummy) never gets a grip joint at all, and neither does a character caught mid-respawn.
		-- The weapon is simply un-animatable for this equip, which is what it already was.
		logger:debug("No grip Weld to motorize", { character = character.Name, tool = tool.Name })
		return
	end
	local weld = grip :: Weld

	local motor = Instance.new("Motor6D")
	motor.Name = GRIP_JOINT_NAME
	motor.Part0 = weld.Part0
	motor.Part1 = weld.Part1
	motor.C0 = weld.C0
	motor.C1 = weld.C1
	motor.Parent = weld.Parent
	weld:Destroy()
end

-- Swaps whatever visual `character` is currently wearing for `weaponId`'s -- or for nothing, if no
-- model is registered under that id (WeaponModels.Build returning nil). The production reaction to
-- AttackRequestSystem.OnWeaponChanged AND the direct entry point a spec drives -- there is no separate
-- private copy of this logic for a test to diverge from.
--
-- Idempotent in effect (re-running it with the same WeaponId a character already holds still rebuilds
-- the Tool) rather than in implementation -- this only ever runs on an actual OnWeaponChanged firing
-- (at most a few times a minute per player, gated by AttackConstants.Network.
-- MaxSwapsPerSecondPerPlayer upstream), not a hot path worth an extra GetAttribute branch to skip.
function WeaponVisualSystem.EquipVisual(character: Model, weaponId: WeaponId?): ()
	local humanoid = CharacterUtil.HumanoidOf(character)
	if not humanoid then
		return
	end

	local existing = character:FindFirstChild(CURRENT_TOOL_NAME)
	if existing then
		existing:Destroy()
	end

	-- nil weaponId is SHEATHED (or empty-handed) -- destroying the existing Tool above is the whole
	-- of it, and returning here is what leaves the character holding nothing. Not an error case: it is
	-- the state every player spawns in, and the one WeaponInventorySystem puts them back into on every
	-- sheath.
	if not weaponId then
		return
	end

	local tool = WeaponModels.Build(weaponId)
	if not tool then
		return
	end
	tool.Name = CURRENT_TOOL_NAME
	tool:SetAttribute(WEAPON_ID_ATTRIBUTE, weaponId)

	-- pcall'd rather than trusted: EquipTool touches a real character rig (RightHand/Right Arm), and a
	-- character caught mid-respawn or otherwise missing the part it needs must not be able to throw out
	-- of a cosmetic system and into AttackRequestSystem's own OnWeaponChanged dispatch loop, which is
	-- already pcall-guarded for exactly this but would otherwise lose the specific reason here.
	local ok, err = pcall(function()
		humanoid:EquipTool(tool)
	end)
	if not ok then
		tool:Destroy()
		logger:warn("Failed to equip weapon visual", { weaponId = weaponId, errorMessage = tostring(err) })
		return
	end

	-- After the equip, never before: the joint being replaced is one EquipTool creates, so there is
	-- nothing to find until it has run. Outside the pcall above rather than inside it because a failure
	-- here must not be mistaken for a failed equip and destroy a weapon the player is legitimately
	-- holding -- MotorizeGrip's own no-grip case returns quietly, and the weapon stays equipped and
	-- un-animated, which is exactly the state every weapon was in before this existed.
	WeaponVisualSystem.MotorizeGrip(character, tool)
end

-- Subscribes to the attack layer's weapon-swap signal, and nothing else. Split out of Init for the
-- same reason GrabSystem.Attach/DamageSystem.Attach are: a spec drives EquipVisual directly and must
-- not also stand up a subscription racing it. Idempotent.
function WeaponVisualSystem.Attach(): ()
	if weaponChangedDisconnect then
		return
	end
	weaponChangedDisconnect = AttackRequestSystem.OnWeaponChanged(WeaponVisualSystem.EquipVisual)
end

function WeaponVisualSystem.Init(): ()
	if started then
		return
	end
	assert(
		AttackRequestSystem.OnWeaponChanged ~= nil,
		"WeaponVisualSystem.Init() requires AttackRequestSystem to be available"
	)
	started = true

	WeaponModelRegistry.Start()
	WeaponVisualSystem.Attach()
	logger:info("WeaponVisualSystem.Init() complete")
end

-- Spec-only, so one case cannot leave a live subscription for the next. The same role
-- GrabSystem.Reset/DamageSystem.Reset play for their own modules.
--
-- DELIBERATELY DOES NOT RESET WeaponModelRegistry, even though Init starts it. That registry is SHARED
-- infrastructure -- WeaponModels reads it to build a Tool and WeaponRoster reads the same folder for
-- the numbers -- so it is not this System's state to clear. It used to be reset here, and the effect
-- was that any spec calling WeaponVisualSystem.Reset() in its teardown silently wiped the templates
-- every OTHER spec file's fixture had registered, which read as "drawing a weapon equips nothing" in
-- whichever file happened to run later. A module that merely STARTS a shared resource does not get to
-- tear it down.
function WeaponVisualSystem.Reset(): ()
	if weaponChangedDisconnect then
		weaponChangedDisconnect()
		weaponChangedDisconnect = nil
	end
	started = false
end

return WeaponVisualSystem :: Types.SystemModule & typeof(WeaponVisualSystem)
