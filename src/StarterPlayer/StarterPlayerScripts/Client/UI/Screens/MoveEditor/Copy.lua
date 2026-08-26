--!strict
--[[
	Copy.lua

	Owns: every word of explanatory text the Move Editor shows an author -- each section's
	description, each individual field's unit and one-or-two-sentence hint, the empty-state card's
	body, and what a server rejection MEANS (Copy.Failures). One module rather than ~60 string
	literals scattered across PropertyEditor.lua, HitboxEditor.lua and ObjectStunEditor.lua, so the
	prose can be read, reviewed and rewritten as prose instead of being hunted for among layout code.

	Lives in the MoveEditor folder rather than ReplicatedStorage/Shared, deliberately. Copy is never
	validated, never persisted, never on the wire, and no server module or other client feature reads
	it -- MoveTypes.lua is in Shared precisely because MoveRegistryManager.Validate consumes it, and
	this fails that test. DraftBinding.lua already establishes the "small module shared WITHIN the
	feature folder" precedent.

	House style for a Hint, worth holding to when adding one:

	  1. Say what the number MEANS in the fiction of the fight, not what the field is named. "How
	     long the attacker charges before the hitbox goes live" beats "the windup duration".
	  2. Say what RAISING it does, since that is the actual question an author has while dragging a
	     slider.
	  3. End with the authoring default ("Default 0.20s") where one exists. That default lives in
	     this sentence and nowhere else -- see NumericField.lua's own header for why this codebase
	     deliberately has no per-field default table and therefore no reset-to-default button.
	  4. Two sentences maximum. The control is right there; this is a caption, not documentation.

	Units NEVER appear in a field's Label -- they belong in Unit, which NumericField renders
	right-aligned on the label row. Several labels used to carry them inline ("Lunge Distance
	(studs)", "Speed (studs/second)"), which read as part of the name and made the column ragged.

	docs/design/move-editor-guide.md quotes this module for its field reference. If the two ever
	disagree, THIS file is right and the doc is stale.
]]

local MoveEditorTypes = require(script.Parent.Types)

type SectionId = MoveEditorTypes.SectionId

local Copy = {}

export type FieldCopy = {
	-- Passed straight to NumericField.Unit. nil for a field with no meaningful unit -- Max Targets is
	-- a count, not a measurement.
	Unit: string?,
	Hint: string,
}

-- Keyed "<Section>.<Field>" so a key names its own location in the UI, and a mistyped one is
-- obvious on sight rather than resolving to some unrelated field's text.
Copy.Fields = {
	-- Basic Info --------------------------------------------------------------------------------
	["BasicInfo.Description"] = {
		Hint = "What this move is FOR, in your own words -- the intent the numbers can't carry. "
			.. "Nothing in combat reads it; it is here so the reasoning outlives the tuning session.",
	} :: FieldCopy,
	-- Animation ---------------------------------------------------------------------------------
	["Animation.Priority"] = {
		Hint = "Which layer this clip plays on. Action sits above locomotion, which is what a swing "
			.. "almost always wants; Core sits under everything and will be hidden by the run cycle. "
			.. "Default Action.",
	} :: FieldCopy,
	-- Offset -----------------------------------------------------------------------------------
	["Offset.X"] = {
		Unit = "studs",
		Hint = "Slides the hitbox left (negative) or right (positive) of the attacker's centre line. Default 0.",
	} :: FieldCopy,
	["Offset.Y"] = {
		Unit = "studs",
		Hint = "Raises or lowers the hitbox. Raise it for an overhead swing, lower it for a sweep at the legs. Default 0.",
	} :: FieldCopy,
	["Offset.Z"] = {
		Unit = "studs",
		Hint = "How far in front of the attacker the hitbox sits. NEGATIVE is forward -- -3 reaches ahead, +3 puts it "
			.. "behind them. Default -3.",
	} :: FieldCopy,

	-- Timing -----------------------------------------------------------------------------------
	["Timing.Windup"] = {
		Unit = "seconds",
		Hint = "How long the attacker telegraphs before the hitbox goes live. This is the window an opponent reads to "
			.. "dodge or parry, so raising it makes the move fairer and easier to punish. Default 0.20s.",
	} :: FieldCopy,
	["Timing.Active"] = {
		Unit = "seconds",
		Hint = "How long the hitbox actually detects targets. Longer is more forgiving to aim with, but lets one swing "
			.. "catch someone who already dodged it. Default 0.15s.",
	} :: FieldCopy,
	["Timing.Recovery"] = {
		Unit = "seconds",
		Hint = "How long the attacker is locked in place after the hitbox closes. This is the punish window if the move "
			.. "whiffs. Default 0.30s.",
	} :: FieldCopy,
	["Timing.Cooldown"] = {
		Unit = "seconds",
		Hint = "Minimum gap between uses, measured from when the move STARTS -- not from when recovery ends. A cooldown "
			.. "shorter than the move's own length does nothing. Default 0.60s.",
	} :: FieldCopy,

	-- Damage -----------------------------------------------------------------------------------
	["Damage.Damage"] = {
		Unit = "HP",
		Hint = "Health removed per target hit. Default 5.",
	} :: FieldCopy,
	["Damage.PostureDamage"] = {
		Unit = "posture",
		Hint = "Poise removed per hit. Filling a target's posture bar breaks their guard and leaves them open, so this "
			.. "is what makes a move good at cracking a blocking opponent. Default 5.",
	} :: FieldCopy,
	["Damage.ArcDegrees"] = {
		Unit = "degrees",
		Hint = "How wide a cone in front of the attacker still counts as a hit. 360 ignores facing entirely; narrow "
			.. "values demand the attacker actually aim. Default 100.",
	} :: FieldCopy,
	["Damage.MaxTargets"] = {
		Hint = "Most targets one swing can hit. Doubles as pierce count when this move is a projectile -- 1 means it "
			.. "stops on the first thing it touches. Default 5.",
	} :: FieldCopy,

	-- Movement ---------------------------------------------------------------------------------
	["Movement.LungeDistance"] = {
		Unit = "studs",
		Hint = "How far the attacker slides forward as the move plays. Closes the gap on a retreating target. "
			.. "Default 8.",
	} :: FieldCopy,
	["Movement.LungeDuration"] = {
		Unit = "seconds",
		Hint = "How long that slide takes. Shorter over the same distance reads as a dash; longer reads as a step. "
			.. "Default 0.20s.",
	} :: FieldCopy,

	-- Knockback --------------------------------------------------------------------------------
	["Knockback.UpVelocity"] = {
		Unit = "studs/s",
		Hint = "Upward launch applied to whoever is hit. This is what pops a target into the air for a juggle. "
			.. "Default 20.",
	} :: FieldCopy,
	["Knockback.HorizontalVelocity"] = {
		Unit = "studs/s",
		Hint = "Push away from the attacker. High values are what drive a target into walls -- see the Object Stun "
			.. "section. Default 10.",
	} :: FieldCopy,
	["Knockback.RagdollSeconds"] = {
		Unit = "seconds",
		Hint = "How long the target stays ragdolled where they land. 0 is a legal, common choice: a clean knock with "
			.. "no floor time. Default 0.60s.",
	} :: FieldCopy,

	-- Grab -------------------------------------------------------------------------------------
	["Grab.HoldSeconds"] = {
		Unit = "seconds",
		Hint = "How long the victim stays pinned to your fist before you must throw them or they drop on their own. "
			.. "Default 3.00s.",
	} :: FieldCopy,
	["Grab.ThrowUpVelocity"] = {
		Unit = "studs/s",
		Hint = "Upward velocity given to the victim's own body the moment you throw them. Real gravity does the rest "
			.. "of the arc. Default 20.",
	} :: FieldCopy,
	["Grab.ThrowHorizontalVelocity"] = {
		Unit = "studs/s",
		Hint = "Forward velocity given to the victim's own body, in the direction you're facing when you throw. "
			.. "Default 55.",
	} :: FieldCopy,
	["Grab.ThrowImpactDamage"] = {
		Unit = "HP",
		Hint = "Health removed from whoever the thrown body collides with on landing. 0 is legal -- a throw that only "
			.. "hurts the person thrown. Default 15.",
	} :: FieldCopy,
	["Grab.ThrowSelfDamage"] = {
		Unit = "HP",
		Hint = "Health removed from the VICTIM themselves on landing -- the cost of being thrown at all, regardless "
			.. "of what (if anything) they hit. Default 10.",
	} :: FieldCopy,

	-- Projectile -------------------------------------------------------------------------------
	["Projectile.Speed"] = {
		Unit = "studs/s",
		Hint = "How fast the hitbox travels once launched. Slow projectiles can be walked around; fast ones are close "
			.. "to hitscan. Default 40.",
	} :: FieldCopy,
	["Projectile.MaxRange"] = {
		Unit = "studs",
		Hint = "How far it flies before expiring. The flight also ends when Active time runs out, so whichever limit "
			.. "comes first wins. Default 60.",
	} :: FieldCopy,
}

-- One per MoveEditor/Types.SectionId, rendered as Section.lua's `description`. Longer than one line
-- is fine now -- that Label auto-heights (see Section.lua's own comment).
Copy.Sections = {
	BasicInfo = "The move's name and grouping tag. Both are for finding it again in this list and in combat logs -- "
		.. "neither affects how the move plays.",
	Hitbox = "The shape and size of the volume that detects targets. Pick a shape first; only the measurements that "
		.. "shape actually uses stay visible below.",
	Offset = "Where that volume sits relative to the attacker. Watch the preview on the right while you change these "
		.. "-- the wireframe is the real hitbox, at the real size.",
	Timing = "How long each phase of the move lasts. Windup, Active and Recovery run back to back and together are the "
		.. "move's full length; Cooldown is measured separately, from the moment it starts.",
	Damage = "What a hit takes off, and how many targets can be caught at once. Posture is the guard-breaking half of "
		.. "the pair -- a move can be built to chip health, to crack blocks, or both.",
	Animation = "The ordered clip timeline that plays over this move. Purely presentational: nothing here changes "
		.. "hitbox timing, so a clip that looks late does not make the move land late.",
	Movement = "An optional forward lunge the ATTACKER performs while the move plays. Off by default -- a plain "
		.. "stationary swing is the normal case.",
	Knockback = "An optional launch and ragdoll applied to whoever is HIT. Off by default. This is also the "
		.. "prerequisite for Object Stun, which needs a target actually in motion to slam into something.",
	Grab = "Instead of ordinary knockback, pin whoever is HIT to your own fist and hold them there. A follow-up "
		.. "press throws them along a real physics arc, dealing damage on landing. Off by default, and the attach "
		.. "point itself is not authored here -- only how long the hold lasts and how hard the throw is.",
	Projectile = "Turns this move into a travelling hitbox instead of a melee one. The shape and size above become the "
		.. "projectile's own volume; it does not gain a separate one.",
	ObjectStun = "What happens when this move's knockback drives a target into world geometry -- a wall, the floor, a "
		.. "pillar. Optional, and the most involved block here: most of it exists to prove the move actually caused "
		.. "the impact rather than firing for anyone who happened to be near a wall.",
	Art = "Turns this move into an unlockable art in one of the cultivation trees. Off by default -- a move "
		.. "stays an ordinary move until you place it in a tree here. Everything you have already authored above "
		.. "(hitbox, timing, damage, animation) is what the art does; this section only decides where it sits, what "
		.. "it costs in Qi, and what a player must do to earn it.",
	Stats = "What this move actually does, computed from the fields you set. Test it on a dummy and the measured "
		.. "results are drawn against the projection on the same axes.",
}

-- The card shown in the content pane while nothing is selected. Replaces a bare one-line
-- "Select or create a move to edit.", which told an admin the state they were in but nothing about
-- what to do next or what this screen is for.
Copy.Empty = {
	Title = "No move selected",
	Body = "Build a custom attack from scratch, or retune one of the game's built-in moves. Everything you change "
		.. "takes effect immediately for Test on Dummy, but only Save writes it to storage.\n\n"
		.. "Start by picking a move from the list on the left, or create a new one.",
	Shortcuts = "Esc close  ·  Ctrl+S save  ·  Ctrl+D duplicate",
}

-- Every keyboard and pointer shortcut this editor answers to, grouped the way the overlay (F1)
-- lists them. Data rather than a block of pre-formatted text so the overlay can lay the key column
-- and the description column out on a real grid instead of relying on padded spaces to line up in a
-- proportional font.
--
-- This list IS the documentation for these bindings -- there is no second place they are written
-- down, which is deliberate: a shortcut an admin cannot discover from inside the tool may as well
-- not exist, and a separate doc would be stale within a pass. Adding a binding means adding a row
-- here in the same change.
export type ShortcutRow = {
	Keys: string,
	Description: string,
}

export type ShortcutGroup = {
	Title: string,
	Rows: { ShortcutRow },
}

Copy.Shortcuts = {
	{
		Title = "Editor",
		Rows = {
			{ Keys = "-", Description = "Open or close the Move Editor." },
			{ Keys = "F1", Description = "Show or hide this list." },
			{ Keys = "Ctrl + S", Description = "Save the open move to storage." },
			{ Keys = "Ctrl + D", Description = "Duplicate the open move (custom moves only)." },
			{ Keys = "Ctrl + Z", Description = "Undo the last field change to this move." },
			{ Keys = "Ctrl + Y", Description = "Redo. Ctrl + Shift + Z does the same." },
			{
				Keys = "Esc",
				Description = "Backs out of one thing at a time: this list, then an armed confirmation, "
					.. "then the editor itself. Closing with unsaved changes asks twice.",
			},
		},
	} :: ShortcutGroup,
	{
		Title = "Numeric fields",
		Rows = {
			{ Keys = "Scroll", Description = "Nudge the field under the pointer by its finest step." },
			{ Keys = "Shift", Description = "Ten times the step, on the -/+ buttons and the wheel." },
			{
				Keys = "Alt",
				Description = "One tenth of the step. Held BEFORE grabbing the bar, it turns the drag "
					.. "into a fine sweep over a tenth of the range.",
			},
			{ Keys = "Click the bar", Description = "Jump to that value. Hold and drag to sweep it." },
			{ Keys = "Click the number", Description = "Type an exact value." },
			{ Keys = "Up / Down", Description = "Nudge the number you are typing, before committing it." },
			{ Keys = "Enter / Esc", Description = "Commit what you typed, or abandon it." },
		},
	} :: ShortcutGroup,
	{
		Title = "Move list",
		Rows = {
			{ Keys = "Double-click", Description = "Rename a move in place. Enter commits, Esc abandons." },
			{ Keys = "Hover a row", Description = "Reveals rename, duplicate and delete for that move." },
			{ Keys = "Delete", Description = "Asks twice -- the second press within a few seconds deletes." },
		},
	} :: ShortcutGroup,
} :: { ShortcutGroup }

-- What a server rejection MEANS, and WHERE the author has to go to fix it.
--
-- Every Save/UpdateDraft failure comes back as a bare machine code (MoveRegistryManager.Validate's
-- own return values plus MoveEditorSystem's handful of transport-level ones), and the editor used to
-- put that code straight into the status line: "Failed to save: InvalidShapeField". That is true and
-- almost useless -- it names neither which field nor which of the thirteen sections that field lives
-- in, and the offending section is very often NOT the one the author is looking at when the save
-- fails, because a save validates the whole record at once.
--
-- So each entry carries a plain sentence AND, where the rejection is about one section's fields, that
-- section's id -- MoveEditorClient.lua jumps the nav there, so the failure message and the controls
-- it is about are on screen together.
--
-- Section is nil for a failure that is not about anything the author typed: a storage outage, an
-- internal error, a move that no longer exists, or one of the four server-stamped identity fields
-- (MoveId/Author/CreatedAt/UpdatedAt), which have no controls to jump to at all. Jumping the nav on
-- one of those would move the author away from their work to prove a point they cannot act on.
export type FailureCopy = {
	Section: SectionId?,
	Message: string,
}

Copy.Failures = {
	-- Basic Info ---------------------------------------------------------------------------------
	InvalidDisplayName = {
		Section = "BasicInfo" :: SectionId,
		Message = "A move needs a display name.",
	} :: FailureCopy,
	InvalidCategory = {
		Section = "BasicInfo" :: SectionId,
		Message = "A move needs a category tag.",
	} :: FailureCopy,
	ReservedCategory = {
		Section = "BasicInfo" :: SectionId,
		Message = "'Default' is reserved for the game's built-in moves -- pick another category.",
	} :: FailureCopy,

	-- Hitbox -------------------------------------------------------------------------------------
	InvalidShape = {
		Section = "Hitbox" :: SectionId,
		Message = "That hitbox shape isn't one the server knows.",
	} :: FailureCopy,
	InvalidShapeField = {
		Section = "Hitbox" :: SectionId,
		Message = "One of the hitbox measurements is out of range for this shape.",
	} :: FailureCopy,
	MissingDimensions = {
		Section = "Hitbox" :: SectionId,
		Message = "This shape needs measurements the move doesn't carry yet.",
	} :: FailureCopy,

	-- Offset / Timing / Damage -------------------------------------------------------------------
	InvalidOffset = {
		Section = "Offset" :: SectionId,
		Message = "The hitbox offset is out of range.",
	} :: FailureCopy,
	InvalidTiming = {
		Section = "Timing" :: SectionId,
		Message = "Windup, Active, Recovery or Cooldown is outside what the engine will resolve.",
	} :: FailureCopy,
	InvalidDamage = {
		Section = "Damage" :: SectionId,
		Message = "Damage or posture damage is out of range.",
	} :: FailureCopy,
	InvalidArcDegrees = {
		Section = "Damage" :: SectionId,
		Message = "The arc is out of range.",
	} :: FailureCopy,
	InvalidMaxTargets = {
		Section = "Damage" :: SectionId,
		Message = "Max targets is out of range.",
	} :: FailureCopy,

	-- Animation ----------------------------------------------------------------------------------
	InvalidAnimationId = {
		Section = "Animation" :: SectionId,
		Message = "An animation id isn't a usable asset reference.",
	} :: FailureCopy,

	-- Optional sub-tables ------------------------------------------------------------------------
	InvalidMovement = {
		Section = "Movement" :: SectionId,
		Message = "The lunge distance or duration is out of range.",
	} :: FailureCopy,
	InvalidKnockback = {
		Section = "Knockback" :: SectionId,
		Message = "One of the knockback numbers is out of range.",
	} :: FailureCopy,
	InvalidGrab = {
		Section = "Grab" :: SectionId,
		Message = "One of the grab or throw numbers is out of range.",
	} :: FailureCopy,
	InvalidProjectile = {
		Section = "Projectile" :: SectionId,
		Message = "Projectile speed or range is out of range.",
	} :: FailureCopy,
	InvalidObjectStun = {
		Section = "ObjectStun" :: SectionId,
		Message = "The object stun block has a value the server won't accept.",
	} :: FailureCopy,
	InvalidObjectStunFollowUp = {
		Section = "ObjectStun" :: SectionId,
		Message = "The object stun follow-up attack has a value the server won't accept.",
	} :: FailureCopy,

	-- Art ----------------------------------------------------------------------------------------
	InvalidArt = {
		Section = "Art" :: SectionId,
		Message = "The art binding isn't readable.",
	} :: FailureCopy,
	InvalidArtTreeId = {
		Section = "Art" :: SectionId,
		Message = "An art needs a tree.",
	} :: FailureCopy,
	UnknownArtTree = {
		Section = "Art" :: SectionId,
		Message = "That art tree no longer exists -- pick one from the list.",
	} :: FailureCopy,
	InvalidArtPrerequisite = {
		Section = "Art" :: SectionId,
		Message = "The prerequisite art id is blank or malformed.",
	} :: FailureCopy,
	SelfReferentialArtPrerequisite = {
		Section = "Art" :: SectionId,
		Message = "An art can't require itself -- it could never be unlocked.",
	} :: FailureCopy,
	-- The Hotbar toolbar's "bind to slot" refusal (ArtSystem.DevGrantAndEquip) -- a move with no Art
	-- binding structurally can't be equipped to a slot (see ArtSystem.lua's own header on why a slot
	-- only ever holds a real Art now). Jumps to Art since that's exactly what's missing.
	NotAnArt = {
		Section = "Art" :: SectionId,
		Message = "This move isn't bound into an art tree yet -- add an Art binding first.",
	} :: FailureCopy,

	-- No section: nothing the author typed, so nothing to jump to ---------------------------------
	InvalidMoveId = { Message = "The server didn't recognise this move's id." } :: FailureCopy,
	InvalidAuthor = { Message = "The server rejected this move's stamped author." } :: FailureCopy,
	InvalidCreatedAt = { Message = "The server rejected this move's stamped creation time." } :: FailureCopy,
	InvalidUpdatedAt = { Message = "The server rejected this move's stamped update time." } :: FailureCopy,
	MoveNotFound = { Message = "That move no longer exists on the server." } :: FailureCopy,
	StorageError = { Message = "Storage is unavailable -- the move is still live, but nothing was written." } :: FailureCopy,
	InternalError = { Message = "The server hit an internal error handling that request." } :: FailureCopy,
}

-- Unlike Copy.Field, this NEVER asserts and never fails: it is called on the failure path, where the
-- reason string came off the wire and is by definition not something this client controls. An
-- unmapped code (a new one added server-side, or a nil) still has to produce something an admin can
-- read and, ideally, quote in a bug report -- so the fallback shows the raw code rather than hiding
-- it behind a generic apology.
function Copy.Failure(reason: string?): FailureCopy
	if reason == nil then
		return { Message = "The server rejected that without saying why." }
	end
	local entry = Copy.Failures[reason]
	if entry then
		return entry
	end
	return { Message = `The server rejected that: {reason}` }
end

-- Asserts rather than returning a blank on an unknown key: a mistyped key should fail loudly the
-- first time that section is opened in Studio, not quietly render a field that lost its explanation
-- and leave nobody any the wiser. ~60 dotted-path keys cannot be a sealed record type without
-- doubling this file's size, so a runtime assert is the check that is actually available.
function Copy.Field(key: string): FieldCopy
	local entry = Copy.Fields[key]
	assert(entry, `Copy.Field: no copy authored for "{key}"`)
	return entry
end

return Copy
