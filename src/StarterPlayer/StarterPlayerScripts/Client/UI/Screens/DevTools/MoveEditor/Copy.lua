--!strict
--[[
	MoveEditor/Copy.lua

	Owns: every sentence the Move Editor shows that is not a field's own label -- what a refusal code
	means, which tab it points at, and the one-line hints under the fields that need one.

	One module so the prose is edited in one place, and so a reason code the server grows is added next
	to its siblings rather than scattered through whichever handler first sees it. A code missing here
	still reads -- as itself -- rather than as a blank.

	Does not own: the codes themselves (Server/Combat/MoveRegistryManager.Validate,
	Server/Systems/MoveEditorSystem, AttackRequestSystem's refusals) or the field labels (the tab
	modules, beside the field they name).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)

local Copy = {}

export type Failure = {
	Message: string,
	-- The form tab that holds the offending field, when there is one; the driver jumps there.
	Tab: string?,
}

local FAILURES: { [string]: Failure } = {
	-- Validation
	InvalidShape = { Message = "The draft was not a move." },
	InvalidMoveId = { Message = "The move has no id." },
	InvalidDisplayName = { Message = "Give the move a name.", Tab = "Identity" },
	InvalidAuthor = { Message = "The move has no author stamp." },
	InvalidTimestamp = { Message = "The move's timestamps are unreadable." },
	InvalidShapeKind = { Message = "That shape does not exist.", Tab = "Hitbox" },
	MissingDimensions = { Message = "The hitbox has no measurements.", Tab = "Hitbox" },
	InvalidOffset = { Message = "The hitbox offset is not a number.", Tab = "Hitbox" },
	InvalidAttachmentPart = { Message = "That anchor does not exist.", Tab = "Hitbox" },
	InvalidTiming = { Message = "A timing field is not a number.", Tab = "Timing" },
	InvalidDamage = { Message = "Damage or posture damage is not a number.", Tab = "Impact" },
	InvalidMaxTargets = { Message = "Max targets is not a number.", Tab = "Hitbox" },
	InvalidAnimationId = { Message = "The animation id is not text.", Tab = "Timing" },
	InvalidKnockback = { Message = "The knockback block is malformed.", Tab = "Impact" },
	InvalidGrab = { Message = "The grab block is malformed, or names a hold mode that does not exist.", Tab = "Impact" },
	InvalidArt = { Message = "The art block is malformed.", Tab = "Identity" },
	InvalidArtTreeId = { Message = "Pick an art tree.", Tab = "Identity" },
	UnknownArtTree = { Message = "That art tree no longer exists.", Tab = "Identity" },
	InvalidArtPrerequisite = { Message = "The prerequisite is not a move id.", Tab = "Identity" },
	SelfReferentialArtPrerequisite = {
		Message = "An art cannot require itself -- it could never be unlocked.",
		Tab = "Identity",
	},

	-- The System
	NotAuthorized = { Message = "Not authorized." },
	RateLimited = { Message = "Too many requests -- try again in a moment." },
	MoveNotFound = { Message = "That move no longer exists." },
	NotCustomMove = { Message = "Only an authored move can be deleted." },
	NotDefaultMove = { Message = "Only a weapon move can be reset to its default." },
	StorageError = { Message = "The DataStore refused the write; it is live but NOT saved." },
	InternalError = { Message = "The server hit an error -- see the Live Console (F5)." },
	InvalidSlot = { Message = "That hotbar slot does not exist." },
	InvalidArtId = { Message = "That is not an art id." },
	NotAnArt = { Message = "Only an art can go in a hotbar slot -- bind it to a tree first.", Tab = "Identity" },
	ProfileNotLoaded = { Message = "Your profile has not loaded yet." },

	-- The test bench (the Dev Menu's own remotes, DevMenuSystem).
	InvalidPreset = { Message = "That bot style or difficulty does not exist." },
	InvalidWeapon = { Message = "That weapon is not in the roster." },
	InvalidRequest = { Message = "The request was malformed." },

	-- A Test swing the attack layer refused -- the same reasons a player's press can meet.
	NoCharacter = { Message = "You have no character to swing with." },
	NotRegistered = { Message = "Your character is not registered with the hitbox engine yet." },
	UnknownMove = { Message = "The combat catalogue cannot resolve this move." },
	Cooldown = { Message = "Still on cooldown." },
	Busy = { Message = "Already swinging." },
	TooManySwings = { Message = "Already swinging." },
	ChainDelay = { Message = "Waiting out the string's beat." },
	Defending = { Message = "Refused: you are guarding or staggered." },
	Hitstun = { Message = "Refused: you are in hitstun." },
	Grabbed = { Message = "Refused: a grab is holding you." },
	AirHeld = { Message = "Refused: you are held in the air." },
	AirCombo = { Message = "Refused: you are mid air string." },
	ParkourAction = { Message = "Refused: mid-traversal." },
	Mounted = { Message = "Refused: you are mounted." },
}

function Copy.Failure(reason: string?): Failure
	local known = if reason then FAILURES[reason] else nil
	return known or { Message = reason or "Unknown error." }
end

-- Field hints. Only for fields whose meaning is not obvious from the label and unit.
Copy.Hints = {
	Anchor = "What the hitbox rides on. Root follows the body; a hand or the weapon follows the animation.",
	LocksMovement = "Locks the attacker's root control for the active window -- for lunges and committed strikes.",
	MaxTargets = "How many different targets one swing may hit.",
	Windup = "Before the hitbox exists. The defender's read -- and a strike marker on the clip overrides it.",
	Active = "How long the hitbox stays open. Never changed by the clip.",
	Recovery = "After the hitbox closes. When the clip's length is known, the clip decides this.",
	MatchTiming = "Types the clip's own timing into Windup and Recovery, so what you typed is what the clip plays. The effective timeline does not change.",
	Cooldown = "Before this move can be thrown again. At or under the swing's length, the swing's end is the gate.",
	AnimationId = "The clip the swing plays and is timed against. Leave blank for none.",
	-- The drain per level is read from the constant it describes, so retuning it cannot leave this stale.
	PowerLevel = `Weight class. Sets how much guard a blocked hit drains ({DefenseConstants.Guard.DrainPerPowerLevel} per level).`,
	Feintable = "Lets the attacker cancel early in the windup to bait a parry.",
	-- Corrected 2026-09-29: DamageResolver applies posture damage as guard pressure on a CLEAN (or
	-- backstab) hit; a blocked hit drains by power level through GuardMeter.DrainFor instead.
	PostureDamage = "Guard pressure a clean hit adds. A BLOCKED hit drains by power level instead.",
	StartsAirCombo = "Makes a landed hit a launcher: it opens an air string, like a weapon's own launcher.",
	Grab = "Instead of knocking the target away, a clean hit holds them until thrown.",
	GrabMode = "How the target is held: lifted in front of you, or dragged behind you along the floor. Dragged targets are thrown onward, away from you.",
	GrabVictimAnimation = "Looped on the held target for the whole hold. Leave blank to have their hands claw at your arm instead.",
	GrabAttackerAnimation = "Looped on you while you hold them. Your gripping hand stays on the target either way.",
	Art = "An art is a move in a tree: players unlock it, equip it to a hotbar slot and spend Qi to cast it.",
	Prerequisite = "The art that must be mastered first (its move id). Leave blank for an entry form.",
	Category = "A grouping tag for this list only. Nothing in combat reads it.",
	Description = "What this move is FOR -- the intent the numbers cannot carry.",
}

return Copy
