--!strict
--[[
	Copy.lua

	Owns: every word of explanatory text the Move Editor shows an author -- each section's
	description, each individual field's unit and one-or-two-sentence hint, and the empty-state card's
	body. One module rather than ~60 string literals scattered across PropertyEditor.lua,
	HitboxEditor.lua and ObjectStunEditor.lua, so the prose can be read, reviewed and rewritten as
	prose instead of being hunted for among layout code.

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
