--!strict
--[[
	AttributeConstants.lua

	Owns: the exact STRING NAME of every Instance Attribute that more than one system reads or
	writes. Nothing else -- not what any of them mean, not who is allowed to set one, not the tiers
	that resolve them. Each name's own comment carries that, and those comments are the real content
	of this file: an Attribute is an untyped, unchecked seam between two modules that do not require
	each other, so the only place the contract can live is next to the name.

	Lifted out of Constants.lua, where it was the single most-reached-for section (66 files) buried
	at line 706 of 2,834. Constants.lua's own header names the precedent and asks for exactly this --
	Constants.Combat and Constants.Flight left the same way, for the same reason.

	Constants.Attributes re-exports this module, so every existing `Constants.Attributes.X` call site
	keeps working unchanged. New code should require this module directly.

	WHY A REGISTRY AT ALL, restated because it is the thing that decays first: these names cross
	module boundaries as bare strings. A typo at a SetAttribute call site does not fail to compile,
	does not fail to lint, and does not raise at runtime -- it silently writes an Attribute nobody
	reads, and the feature simply never happens. Naming each one once is the only check there is.

	THE TABLE IS NOT UNIFORM AND MUST NOT BE MADE SO. Three axes vary per entry, and each one is
	stated in that entry's own comment because getting it wrong is silent:
	  * WHO WRITES IT -- most are server-written, but ParkourFacingOwned, ParkourActionOwned and
	    UiModalOpen are client-written and therefore do NOT replicate. A client-set Attribute can
	    never be an authority; the server's own gate always is.
	  * WHAT IT HANGS ON -- every entry here is a Humanoid Attribute except UiModalOpen, which lives
	    on the Player because it has to outlive the character across a respawn.
	  * WHETHER IT IS A FLAG OR A DEADLINE -- CombatBusyUntil and ParkourSpeedFloorExpiry are
	    os.clock() timestamps precisely so nothing has to remember to clear them. A stale deadline has
	    merely passed; a stale `true` strands the player forever with no error to explain it.

	Does not own: the resolution ORDER these feed (Server/Systems/RunSystem.lua's WalkSpeed tiers),
	the systems that publish them, or any alias another module keeps onto one of these names
	(Shared/Defense/DefenseConstants.lua's DefenseStateAttribute aliases DefenseState -- that alias
	points here, this file does not point back).
]]

local AttributeConstants = {
	Flying = "Flying",
	Godmode = "Godmode",
	FlyCollide = "FlyCollide",
	RootControlLocked = "RootControlLocked",
	-- DefenseSystem's published block/parry/stagger state (Shared/Defense/DefenseConstants.lua's
	-- DefenseStateAttribute aliases onto this) -- RunSystem.lua reads it directly, so it belongs in
	-- this registry alongside every other cross-system Attribute name rather than living only in
	-- DefenseConstants.
	DefenseState = "DefenseState",
	BonusWalkSpeed = "BonusWalkSpeed",
	-- Admin-only movement lock (DevMenuSystem.lua's SetTargetFrozen) -- Movement.
	-- ComputeDesiredWalkSpeed reads this directly (same "external override, read as an Attribute"
	-- shape as Flying above), pinned to top priority, above even Flying.
	Frozen = "Frozen",
	-- Admin-only WalkSpeed scale (DevMenuSystem.lua's SetTargetSpeedMultiplier) -- read by Movement.
	-- ComputeDesiredWalkSpeed as a multiplier on `base`, same "per-player Humanoid Attribute" shape
	-- BonusWalkSpeed already uses, defaulting to 1 (no change) when unset.
	SpeedMultiplier = "SpeedMultiplier",
	-- Admin-only invisibility (DevMenuSystem.lua's SetTargetInvisible) -- mirrored here purely so
	-- DevMenuClient.lua can reflect live state in the Admin tab UI, same as Godmode; the actual
	-- effect is a direct Transparency write on every BasePart/Decal (CombatSystem.
	-- SetPlayerInvisible), not something Server/Systems/RunSystem.lua or any per-frame resolver reads.
	Invisible = "Invisible",
	-- Emote System (Server/Systems/EmoteSystem.lua) -- set/cleared directly on the emoting
	-- character's Humanoid while a MovementLocked emote (Types.EmoteDefinition.MovementLocked) is
	-- playing/stopping/cancelled. Same "external system freezes movement by publishing an Attribute"
	-- shape as Frozen/Flying above -- Server/Systems/RunSystem.lua's own resolver reads this directly,
	-- at the same top priority tier, rather than EmoteSystem reaching into the run state (which it has
	-- no ownership of).
	EmoteMovementLocked = "EmoteMovementLocked",
	-- Whether this player is currently IN COMBAT (CombatState.inCombatUntil still live) -- written by
	-- CombatSystem's inCombatNotifier on each true/false edge, alongside the Combat_InCombatChanged
	-- remote it already fires for the HUD badge. Same "one Attribute the server publishes, read
	-- directly by whoever needs it" shape as RootControlLocked above.
	--
	-- Exists because Client/Parkour needs it and the remote does not suit that consumer: the parkour
	-- context is rebuilt from Humanoid Attributes every frame (see ParkourController's own
	-- resolveCombatOwned, which reads four of them), so an Attribute costs one more read on a value
	-- that is already being maintained, where the remote would mean a second subscription and a cached
	-- mirror to keep in sync across respawns. Deliberately NOT a replacement for the remote -- the HUD
	-- badge wants the edge, parkour wants the level.
	--
	-- Note this makes InCombat gameplay-affecting in a third place (passive health regen and the
	-- parkour combat gate now both hang off inCombatUntil), so tuning InCombatDurationSeconds or
	-- CombatEngagementRange reaches further than it used to. See syncInCombat's own header.
	InCombat = "InCombat",
	-- Attack layer (Server/Combat/Attack/AttackRequestSystem.lua). An os.clock() timestamp: the moment
	-- the swing this combatant is currently committed to finishes its windup, active and recovery. 0 or
	-- unset means no swing is committing them.
	--
	-- THIS IS THE SEAM Server/Systems/RunSystem.lua's header asked for by name -- "when [the combat
	-- layer] comes back it should publish its own speed effect as an Attribute and this file grows one
	-- tier", the same way Frozen, Flying and EmoteMovementLocked already work without the Systems that
	-- own them knowing RunSystem exists. What that tier does with it is force the run down: throwing a
	-- swing drops the stage to 0 and zeroes the charge, so a player has to be walking to fight and has
	-- to re-earn the gear afterwards.
	--
	-- A TIMESTAMP RATHER THAN A BOOLEAN, for the same reason ParkourSpeedFloorExpiry is one: nothing
	-- has to remember to clear it. A swing that ends by interruption, a character that dies mid-string,
	-- a System that stops running -- all of them leave a stale deadline that has simply passed, where a
	-- stale `true` would leave that player unable to reach second gear again for the rest of their life
	-- with no error anywhere to explain it.
	CombatBusyUntil = "CombatBusyUntil",
	-- Whether this client currently has a modal UI panel open -- the character menu, Settings, the
	-- Move Editor, the Live Console, DevMenu, the bug reporter. Written by
	-- Client/UI/Components/ModalScreen.lua (the one thing that creates a modal, so it is the one
	-- thing that can count them); read by every input consumer that must not fire while the player is
	-- reading a panel rather than fighting.
	--
	-- THE ONE ATTRIBUTE IN THIS TABLE THAT LIVES ON THE PLAYER, NOT THE HUMANOID, and the one that
	-- never leaves the client. It has to outlive the character (a menu stays open across a respawn),
	-- and nothing on the server has any business knowing what the player is looking at. It is
	-- registered here anyway because the whole point of this table is that an Attribute name shared
	-- by two modules is written down once -- Client/UI writes it and Client/Combat reads it, two
	-- folders with no shared module between them, which is exactly the coupling this registry exists
	-- to keep honest.
	--
	-- A COUNT-BACKED BOOLEAN, not a raw flag: two panels can be open at once (the Move Editor over
	-- the character menu), so ModalScreen tracks how many are open and publishes `count > 0`. A plain
	-- boolean would let closing either one re-arm the player's fists while the other is still up.
	UiModalOpen = "UiModalOpen",
	-- Parkour System (Server/Systems/ParkourSystem.lua, Client/Parkour/*). Set on a player's own
	-- Humanoid while the client-side movement framework legitimately owns that character's velocity --
	-- a slide, wall-run, vault, mantle, ledge climb, roll or wall-jump the server has accepted and not
	-- yet expired. Server/Systems/RunSystem.lua's resolver reads it directly and pins WalkSpeed to 0
	-- for the duration, at the same tier as Flying/Frozen/EmoteMovementLocked and for the identical
	-- reason: something other than the ordinary ground controller is driving this body, and a raised
	-- WalkSpeed underneath it fights the drive instead of riding along with it. Same "external system,
	-- read as an Attribute" shape those three already use, which is what
	-- lets ParkourSystem stay entirely outside CombatSystem's private state.
	ParkourVelocityOwned = "ParkourVelocityOwned",
	-- The COMBAT-GATE counterpart to ParkourVelocityOwned above, and like ParkourFacingOwned below it
	-- is written by the CLIENT rather than the server: Client/Parkour/ParkourController.lua raises it
	-- on every transition into a state Shared/Parkour/ParkourOwnership.IsActionState calls an action,
	-- and Client/Combat/AttackInputClient.lua and Client/Defense/DefenseClient.lua read it to decline
	-- to SEND a press they can already see the server will refuse.
	--
	-- IT EXISTS FOR EXACTLY ONE STATE'S WORTH OF DIFFERENCE, and that is worth stating plainly so
	-- nobody deletes it as a duplicate. ParkourVelocityOwned is raised only for a REPORTED action
	-- (ParkourTypes.ActionKind), and every action state declares a Reports kind except
	-- States/LedgeHanging.lua -- so a player hanging on a ledge is invisible to the server's own gate
	-- and could otherwise punch from the hang. The permanent fix is that state reporting like its
	-- neighbours, which is a parkour-layer change with its own validation and momentum-carry
	-- consequences; until then this closes the hole from the one machine that can see it.
	--
	-- Client-set, so it does NOT replicate -- writer and readers are all on the same client, exactly
	-- like ParkourFacingOwned. That is also why it can never be the authority: the server's own gate in
	-- AttackRequestSystem.Throw is, and a client that simply declines to write this gets refused there
	-- for everything except the hang.
	ParkourActionOwned = "ParkourActionOwned",
	-- The ROTATION counterpart to ParkourVelocityOwned above, and unlike every other Attribute in this
	-- table it is written by the CLIENT, not the server: Client/Parkour/ParkourMotor.lua raises it for
	-- exactly the window in which it owns the character's facing (the AlignOrientation drive in Velocity
	-- mode, the anchored CFrame write in Kinematic mode), and Client/Camera/ShiftLockCamera.lua reads it
	-- to stand its own per-frame yaw write down for the duration. Both ends are on the same client and
	-- nothing on the server reads it, so client-set (which does not replicate) is exactly right --
	-- this is one client-side presentation module coordinating with another, which is why it is an
	-- Attribute rather than a NetworkBridge remote.
	--
	-- It exists as an Attribute rather than a direct ParkourMotor -> ShiftLockCamera function call to
	-- keep the require graph one-directional: the camera folder is not mounted in test.project.json, so
	-- requiring it from the motor would drag Fusion and the whole camera stack into the parkour state
	-- registry's load chain and break Tests/Parkour/StateRegistry.spec. Same reactive
	-- GetAttributeChangedSignal shape ShiftLockCamera already uses for Flying/RootControlLocked, so it
	-- costs that module a cached boolean and no new dependency in either direction.
	ParkourFacingOwned = "ParkourFacingOwned",
	-- The momentum a just-finished parkour action handed back, as an absolute WalkSpeed floor, plus the
	-- timestamp it decays to nothing at. Together these are how a slide's or a vault's earned speed
	-- survives into ordinary running instead of being erased the instant the action ends -- see
	-- Server/Systems/RunSystem.lua's own parkourSpeedFloor. Deliberately a FLOOR under the normal
	-- tiers rather than a replacement for them, so it can only ever preserve speed a player earned and
	-- never slow anyone down, and deliberately applied only to the ladder's own answer -- never to the
	-- zeroing tiers above it, so it cannot peek through a freeze, a flight or a parkour claim. There
	-- are no hit-slow or stun tiers for it to sit below any more; the combat rewrite left none.
	ParkourSpeedFloor = "ParkourSpeedFloor",
	ParkourSpeedFloorExpiry = "ParkourSpeedFloorExpiry",
	-- The movement state that player's client last reported (a Types.ParkourActionReport Kind, or the
	-- empty string for ordinary locomotion). Purely informational: nothing gates on it. It exists
	-- because Humanoid Attributes replicate to every client for free, so this gives other players'
	-- clients -- and any future spectator/replay tooling -- a way to know what a remote character is
	-- doing without this feature adding a broadcast remote of its own.
	ParkourState = "ParkourState",
	-- Run System (Server/Systems/RunSystem.lua, Client/Movement/RunController.lua). The sustained-run
	-- STAGE this player's server-side state currently resolves to: 0 = not running (or running but
	-- not actually being granted the tier), 1/2 = the ladder Shared/Run/RunConstants.lua's Stages
	-- array defines -- that file, not this one, is the single source of truth for the thresholds and
	-- speeds behind each stage.
	--
	-- Server-written, exactly like every other Attribute in this table except ParkourFacingOwned, and
	-- for the reason that makes this feature safe: the stage decides a WalkSpeed multiplier, so the
	-- client must never be the one that decides it. The client only READS this to pick which run clip,
	-- which footstep sound and which FOV offset to present -- if a client lies to itself about the
	-- stage it gets a wrong animation and no extra speed at all.
	--
	-- An Attribute rather than a remote for the same reason ParkourState above is one: Humanoid
	-- Attributes replicate to every client for free, so a remote player's own client can pick the
	-- matching run animation for them with no per-stage broadcast of our own.
	SprintStage = "SprintStage",
	-- Grab layer (Server/Combat/Grab/GrabSystem.lua). Set true on the VICTIM's Humanoid for the whole
	-- hold-then-flight lifetime (a hold in progress OR a thrown body still in the air), cleared the
	-- instant control is handed back -- landing, a dropped hold, or a disconnect. Added to
	-- RunSystem.isMovementLocked's tier list so a grabbed player's own WalkSpeed pins to 0, the same
	-- "external system freezes movement without touching CombatState/RunSystem's own resolver" shape
	-- Frozen/Flying/EmoteMovementLocked already use.
	--
	-- A NEW Attribute rather than reusing RootControlLocked for this half of the job -- see
	-- RootControlLocked's own header just above and GrabSystem.lua's header for the full reasoning:
	-- RootControlLocked has never carried WalkSpeed-zeroing semantics in this codebase (a dedicated
	-- Attribute always did, historically HoldAloft's own airComboChaseExpiry), so widening its meaning
	-- now would quietly change what every OTHER historical setter of it was ever promising.
	Grabbed = "Grabbed",
	-- Blimp layer (Server/Systems/BlimpSystem.lua). Set true on a MOUNTED player's Humanoid for the whole
	-- time they are welded to a station -- helm or handhold, both -- and cleared by BlimpSystem.Dismount,
	-- which is the single release path every one of the six ways off a blimp ends in. Added to
	-- RunSystem.isMovementLocked's tier list so a mounted player's WalkSpeed pins to 0, the same shape
	-- Grabbed above already uses and for exactly the same reason it is a separate Attribute rather than a
	-- widened RootControlLocked (BlimpSystem sets BOTH: RootControlLocked to park client-side parkour,
	-- this one to zero the speed).
	Mounted = "Mounted",
	-- The ATTACKER-side half of the same lifetime -- true only while GrabSystem holds a victim for this
	-- combatant, cleared the instant they Throw or the hold auto-releases. Read by
	-- Client/Combat/GrabInputClient.lua to gate sending Grab_Throw (the same "the client declines to
	-- send what it can already see is illegal" convention Shared/Parkour/ParkourOwnership.OwnsBody
	-- already establishes) and to drive the "HOLDING -- [G] to throw" cue. NOT consulted by
	-- GrabSystem.CanAttack itself -- that reads its own internal `holds` table directly, since it is
	-- the authority this Attribute only mirrors.
	Grabbing = "Grabbing",
}

return AttributeConstants
