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
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)

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
	InvalidProjectile = {
		Message = "The projectile block is malformed, or names an option that does not exist.",
		Tab = "Hitbox",
	},
	ProjectileCannotGrab = {
		Message = "A projectile move cannot grab -- turn the grab off, or make the move melee.",
		Tab = "Impact",
	},
	InvalidDomain = {
		Message = "The realm block is malformed, or names an option that does not exist.",
		Tab = "Domain",
	},
	InvalidDomainEffect = {
		Message = "A realm effect is malformed -- a kind, a filter or a move id in it is not what it should be.",
		Tab = "Domain",
	},
	InvalidDomainRule = {
		Message = "A realm rule is malformed -- a kind, a filter or a move id in it is not what it should be.",
		Tab = "Domain",
	},
	InvalidDomainClash = {
		Message = "A clash override is malformed, or names no opposing realm.",
		Tab = "Domain",
	},
	DomainEffectNeedsMove = {
		Message = "A Volley or Owner cast effect needs a move id to deliver. (A Strike may leave it blank: that is the realm's own strike.)",
		Tab = "Domain",
	},
	DomainRuleNeedsMove = {
		Message = "A Seal move rule needs the id of the move it seals.",
		Tab = "Domain",
	},
	DomainSelfReference = {
		Message = "A realm effect cannot deliver the realm's own move -- it would re-open itself.",
		Tab = "Domain",
	},
	DomainCannotGrab = {
		Message = "A move that opens a realm cannot also grab -- turn one of them off.",
		Tab = "Impact",
	},
	InvalidPresentation = {
		Message = "The presentation block is malformed -- a cue or a number in it is not what it should be.",
		Tab = "Presentation",
	},
	UnknownPresentationMoment = {
		Message = "The presentation names a moment that does not exist.",
		Tab = "Presentation",
	},
	UnknownPresentationPreset = {
		Message = "A presentation choice names a preset that does not exist.",
		Tab = "Presentation",
	},
	InvalidPresentationAsset = {
		Message = "A presentation id is not an asset id -- paste rbxassetid://..., a bare number, or None for a sound.",
		Tab = "Presentation",
	},
	InvalidPresentationColor = {
		Message = "A presentation colour is not a colour -- use #RRGGBB (or None where offered).",
		Tab = "Presentation",
	},
	InvalidPresentationTemplate = {
		Message = "A template name has characters a name cannot have, or is too long.",
		Tab = "Presentation",
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

	-- Writing to source (Studio only).
	NotStudio = { Message = "Only available in Studio -- a live server cannot write the game's source." },
	HttpDisabled = { Message = "Turn on Game Settings > Security > Allow HTTP Requests, then try again." },
	WriterUnreachable = { Message = "The source writer is not running: run python scripts/move-writer.py." },
	WriterRefused = { Message = "The source writer refused the file -- see its console." },
	NotInSource = { Message = "This move is not in the game's source.", Tab = "Tools" },
	InSource = { Message = "This move ships in source: remove it from source first (Tools tab).", Tab = "Tools" },

	-- Version history.
	InvalidVersion = { Message = "That is not a version number.", Tab = "Tools" },
	VersionNotFound = { Message = "That version is no longer kept -- reload the history.", Tab = "Tools" },

	-- Bulk edit.
	NoMovesMatched = { Message = "No move in that group (and stage) to scale.", Tab = "Tools" },
	TooManyMoves = { Message = "That group is too large to scale in one go -- narrow it to a stage.", Tab = "Tools" },

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
	DomainSealed = { Message = "Refused: a realm you stand in seals this move." },
	DomainActive = { Message = "Refused: your own realm is still up -- one at a time." },
}

function Copy.Failure(reason: string?): Failure
	local known = if reason then FAILURES[reason] else nil
	return known or { Message = reason or "Unknown error." }
end

-- Field hints. Only for fields whose meaning is not obvious from the label and unit.
Copy.Hints = {
	Anchor = "What the hitbox rides on. Root follows the body; a hand or the weapon follows the animation.",
	LocksWindup = "Holds the attacker in place -- no walking, no jumping -- from the moment the move starts until its windup ends, then lets go. Turn on 'while active' as well to hold them through the whole move.",
	LocksMovement = "Holds the attacker in place -- no walking, no jumping -- from the start of the active window through recovery. For committed strikes; a locked swing does not lunge.",
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
	GrabVictimAnimation = "Looped on the held target while you hold them. Leave blank to have their hands claw at your arm instead.",
	GrabAttackerAnimation = "Looped on you while you hold them. Your gripping hand stays on the target either way.",
	GrabThrowAnimation = "Played once when you press throw. The target stays in your hand until the release point below. Blank throws at once.",
	GrabVictimThrowAnimation = "Played once on the target from the moment you press throw, through your throw clip and their flight, instead of their held animation. Cut when they land.",
	GrabThrowReleaseAt = "How far through the throw clip the target leaves your hand: 0.5 is halfway, 1 is the last frame. The clip plays on after it as the follow-through.",
	Art = "An art is a move in a tree: players unlock it, equip it to a hotbar slot and spend Qi to cast it.",
	Prerequisite = "The art that must be mastered first (its move id). Leave blank for an entry form.",
	Category = "A grouping tag for this list only. Nothing in combat reads it.",
	Description = "What this move is FOR -- the intent the numbers cannot carry.",
	-- Projectile moves (ProjectileTypes' header is the long version of each of these).
	MoveType = "Melee hits with a volume on the body. Projectile launches shots when the active window opens -- same timing, block, parry and damage.",
	SpawnPoint = "Where the shots spawn: the anchor, plus the offset below. Yaw and pitch aim the volley; roll turns its spread (a rolled fan is vertical).",
	SpreadAngle = "Fan: the arc every shot shares, end to end (360 is a full ring). Ring: how wide the cone the shots form.",
	ProjectileSize = "The radius of the sphere that flies -- the drawn shot is exactly the volume that hits.",
	Gravity = "Pulls shots down; negative floats them up. Zero flies straight.",
	Homing = "Turns each shot toward a target within the range and angle below, at the strength's rate.",
	Piercing = "Passes through the targets it hits, up to Max pierces; otherwise the first target stops it.",
	-- The grace is read from the constant it describes, like PowerLevel's drain above.
	CanHitOwner = `Lets a shot that comes back hit whoever threw it -- never in its first {HitboxEngineConstants.Projectile.OwnerHitGraceSeconds}s.`,
	ParryResponse = "What a parry does to the shot. Reflect and Reverse hand it to the parrier; only Existing parry staggers the thrower.",
	-- The Presentation tab's fields (MovePresentationTypes), keyed Presentation<Field>.
	PresentationSoundId = "rbxassetid://..., a bare id, or None for silence. Blank keeps what plays today.",
	PresentationVolume = "Times the sound that plays -- this move's, the weapon's or the default.",
	PresentationPitch = "Times the sound's pitch.",
	PresentationPitchVariance = "Random pitch spread per play, so a repeated sound is not a metronome.",
	PresentationRolloffDistance = "0 plays at full volume everywhere. Above 0 it plays from the spot and fades out by this distance.",
	PresentationSoundDelay = "Shifts ONLY the sound from its moment: + plays it later, - earlier. An earlier sound needs the moment known ahead -- a swing's active hit and recovery, a realm's established and fold; elsewhere it plays on the moment.",
	PresentationLoop = "Repeats this cue's own sound from its moment until the move ends, then stops -- with Fade out, sinking onto the last instant. Needs a Sound id of its own. A cancelled swing, or a realm that collapses, stops it early.",
	PresentationFadeIn = "Seconds for the sound to rise from silence. 0 starts it at full volume. Set Fade out too for a fade in AND out.",
	PresentationFadeOut = "Seconds the sound takes to sink back to silence, ending where the sound ends. 0 lets it end as recorded.",
	PresentationAudience = "Participants: only the thrower and the shot's homing target (a realm: its owner and the bodies it governs).",
	PresentationSparks = "Which spark burst plays here. None removes the default one.",
	PresentationSparkColor = "#RRGGBB. Blank keeps the preset's colours.",
	PresentationSparkTexture = "An Image id for the particles (not a Decal id). Blank keeps the default sparkle.",
	PresentationShake = "Replaces the camera shake for both fighters. Respects the player's comfort setting.",
	PresentationFovPunch = "A quick field-of-view kick. Respects the player's comfort setting.",
	PresentationFlashColor = "#RRGGBB, or None for no flash on the target.",
	PresentationHitStopSeconds = "The freeze both bodies hold on contact. Presentation only: the target's real hitstun is not changed.",
	PresentationTrailColor = "#RRGGBB, or None for no trail.",
	PresentationTemplate = "The name of an effect in ReplicatedStorage.MoveFX, played here.",
	PresentationCoreColor = "#RRGGBB. On a realm: its tint. On a shot: its core.",
	PresentationGlowColor = "#RRGGBB. On a realm: its edge. On a shot: its glow.",
}

-- The Domain tab (Shared/Domain/DomainTypes.lua's header is the long version of all of it).
Copy.Domain = {
	Intro = "A realm is a move: its swing is the activation, its clip the animation, its cooldown the realm's cooldown, and its art binding's Qi the cost. This tab is what the swing does not already say.",
	DefaultMove = "A weapon stage cannot open a realm.",
	QiCostNotArt = "No Qi cost yet: bind the move to an art tree (Identity tab) to give it one -- that is also what lets a player put it on the hotbar.",
	Presentation = "What the realm looks and sounds like lives on the Presentation tab: its four Realm moments.",
	Hints = {
		ActivationSeconds = "The unfurl, after the move's windup: the boundary grows, nothing is governed yet, and the owner is exposed.",
		ActiveSeconds = "How long the law holds once established.",
		EndSeconds = "The fold: rules and effects have already stopped; only the visual remains.",
		UpkeepQiPerSecond = "Drained from the owner while the realm holds. Running dry collapses it. Feeds Qi Deviation like any spend.",
		MaxTargets = "Bodies the realm can govern at once, nearest first. Anyone past it is left alone.",
		Radius = "A sphere or cylinder's radius; a box's half-width.",
		Height = "A cylinder or box's full height, centred on the realm.",
		Anchor = "Fixed stays where it opened. Follow owner moves with them (and cannot be walled).",
		CenterForward = "Studs along the owner's facing to centre the realm. Negative is behind.",
		EntryRule = "Barred repels anyone who was not inside when the realm was established.",
		ExitRule = "Barred holds everyone who was. The owner is never held.",
		EntryGraceSeconds = "How long a newcomer stands inside before any effect targets them.",
		ExitLingerSeconds = "How long a leaver keeps the realm's rules.",
		BoundaryCollision = "A physical wall to every body, both ways -- the sealed realm. Fixed realms only.",
		ProjectilesEnter = "Off: shots from outside stop at the edge.",
		ProjectilesLeave = "Off: shots from inside stop at the edge. The realm's own strikes are never stopped.",
		CancelOnOwnerHit = "A hit landed on the owner while the realm is unfurling collapses it. A cut swing always does.",
		CancelOnOwnerExit = "The owner stepping out of their own fixed realm collapses it.",
		Priority = "Higher wins a clash. A tie goes to the later realm's tie-break.",
		ClashBehavior = "What this realm does to a weaker one it overlaps.",
		TieBreak = "When this realm walks into one of equal priority. Contest: both hold, weakened.",
		ErodeRate = "Seconds of the loser's time this realm wears away per second of overlap (Erode).",
		ContestScale = "How much of this realm's effects and rules survive a contest. 1 is all.",
		Interacts = "Off: this realm ignores every other, and they ignore it.",
		EffectMoveId = "The move this effect delivers -- its damage, knockback and hit cues are that move's. A Strike may leave it blank: it then hits for THIS move's own Damage, Posture damage, Power level and Knockback (Impact tab).",
		EffectPower = "Multiplies the price of each hit this effect lands. 1 is the move's price; 2 hits twice as hard.",
		Parryable = "Off: a parry reads as a held guard against this strike.",
		Origin = "Where each strike comes from: above the target, the realm's centre, the owner, or a random point on a ring.",
		TravelSeconds = "How long a strike takes to arrive -- the target's window to read it.",
		RuleValue = "A multiplier: 0.5 halves, 2 doubles.",
		SealMoveId = "The move bodies under this rule may not throw.",
		OpponentMoveId = "The other realm's move id this override answers.",
	} :: { [string]: string },
	-- Short labels per option, in the editor's dropdowns.
	EffectKinds = {
		Strike = "Strike -- deliver a move to each target",
		Volley = "Volley -- launch a projectile move at each target",
		Hitstun = "Stun",
		GuardDrain = "Drain posture",
		Pull = "Pull toward the centre",
		Push = "Push away from the centre",
		OwnerCast = "Owner casts a move",
	} :: { [string]: string },
	RuleKinds = {
		DamageDealt = "Damage dealt",
		DamageTaken = "Damage taken",
		GuardDamageTaken = "Posture damage taken",
		HitstunTaken = "Hitstun taken",
		MoveSpeed = "Movement speed",
		Cooldown = "Cooldowns",
		SealMove = "Seal a move",
		SealArts = "Seal arts",
		SealProjectiles = "Seal projectile moves",
		SealDomains = "Seal realms",
		NoBlock = "No blocking",
		NoParry = "No parrying",
		NoEvade = "No evading",
		NoParkour = "No escape mobility",
		Rooted = "Rooted",
	} :: { [string]: string },
	TargetFilters = {
		Enemies = "Enemies",
		Allies = "Allies",
		Owner = "The owner",
		OwnerAndAllies = "Owner and allies",
		EveryoneButOwner = "Everyone but the owner",
		Everyone = "Everyone",
	} :: { [string]: string },
	ClashBehaviors = {
		Coexist = "Coexist -- both hold",
		Suppress = "Suppress -- only mine holds in the overlap",
		Erode = "Erode -- suppress, and wear theirs away",
		Dominate = "Dominate -- theirs collapses",
		Shatter = "Shatter -- both collapse",
	} :: { [string]: string },
}

-- The Presentation tab (MovePresentationTypes' header is the long version of all of it).
Copy.Presentation = {
	Precedence = "Every field is optional. Left blank, a moment plays what it always played: the weapon's own sound where it has one, else the game's default. Only None silences or hides.",
	Melee = "Projectile moments appear once the move is a projectile (Hitbox tab).",
	NoRealm = "Realm moments appear once the move opens a realm (Domain tab).",
	-- Under each moment's heading: when it fires, and who sees it.
	Moments = {
		Windup = "As the swing starts. Only the thrower's client knows a swing started, so only they see and hear it.",
		Active = "As the hit window opens. The sound here IS the swing whoosh; blank keeps the weapon's own. Only the thrower.",
		Recovery = "As the hit window closes. Only the thrower.",
		HitClean = "A clean hit. Both fighters see it at the contact.",
		HitBlocked = "A blocked hit. Blank keeps the defender's weapon clang.",
		HitParried = "A parried hit. Blank keeps the defender's weapon parry sound.",
		HitPerfectParry = "A perfect parry. Anything blank here uses the Parried cue above first.",
		HitGuardBroken = "A block that breaks the guard.",
		HitBackstab = "A hit from behind through a guard.",
		HitTrade = "Two swings met: a clash, or both fighters parried each other.",
		HitEvaded = "The swing went through an evade. No flash and no freeze: nothing was touched.",
		Launch = "Once per volley, as it launches. Every client sees it; camera cues only the thrower's.",
		InFlight = "The shot itself, for its whole flight. The core stays the hit volume -- size scales the glow and trail. One loop per volley.",
		Bounce = "Each bounce off the world.",
		WorldImpact = "A shot that ends on the world. Blank keeps the default scatter.",
		End = "A shot that runs out of range or lifetime. A shot that hits a body plays the Hit cues instead.",
		DomainOpen = "As the realm begins to unfurl, at its centre. Every client; camera cues only the owner and those inside.",
		DomainActive = "As the realm is established. Its core colour tints the realm (and the screen of anyone under its law); its glow draws the edge.",
		DomainPulse = "Each time one of the realm's effects fires, at every body it reached. A strike's shot and its hit play their own cues on top.",
		DomainClose = "As the realm starts to fold away -- on time, or collapsed early.",
	} :: { [string]: string },
}

return Copy
