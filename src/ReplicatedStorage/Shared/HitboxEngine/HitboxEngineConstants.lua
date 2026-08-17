--!strict
--[[
	HitboxEngineConstants.lua

	Owns: the hitbox engine's own tunables. Deliberately NOT a section of Shared/Constants.lua --
	this engine is standalone, and a module that can be dropped in or pulled out without editing the
	game's central constants table is the concrete form of that. Nothing outside HitboxEngine/ reads
	this file.

	THE SUBSTEP FLOOR is the important number here, so it gets the long explanation.

	A hitbox that only asks "is anyone inside me right now?" once per Heartbeat has a hole in it whose
	size is the frame time multiplied by how fast the volume is moving. At 60Hz a hand travelling
	60 studs/second moves a full stud between samples; a 200ms server hitch moves it twelve. Anything
	thinner than that gap -- which is most of a humanoid, edge-on -- can be on one side of the hitbox
	at sample N and the far side at sample N+1, having never once been inside it when the question was
	asked. The swing visibly passes through the target and reports nothing. That is the single most
	common complaint about naive Roblox hitboxes and it is why the old system's per-Heartbeat sampling
	was not good enough.

	MinSubstepSeconds decouples SAMPLE rate from FRAME rate. When a Heartbeat delivers more time than
	this, the engine subdivides that one frame into several interpolated substeps and runs the whole
	pipeline (state machine advancement AND hit sampling) at each of them, against poses lerped
	between last frame's attachment CFrame and this frame's. Two distinct failures are fixed by the
	same mechanism:
	  * A fast swing tunnelling between samples, as above.
	  * A short Active window falling ENTIRELY between two Heartbeats -- a 60ms active hitbox simply
	    never existing on a frame that took 200ms. Advancing the state machine in substeps rather than
	    in one jump is what makes that window real regardless of server load.

	Substeps are also why SweptContainsPoint exists rather than substeps alone being enough: substeps
	shrink the gap, the swept test closes what is left of it.

	MaxSubstepsPerFrame is the counterweight. Subdividing an already-catastrophic frame into fifty
	steps burns time the server does not have and deepens the hitch that caused it -- so past the cap
	the engine accepts a coarser sample rather than making the stall worse. Bounding the worst case
	instead of letting it scale with load is the same reasoning behind MaxActiveSwings and
	MaxCandidatesPerSample below.

	Does not own: anything about a specific attack (that is an AttackDefinition the caller authors),
	nor any gameplay number -- there is no damage, no cooldown and no range figure in this file,
	because the engine those would belong to does not decide any of it.
]]

local HitboxEngineConstants = {}

-- Sampling ---------------------------------------------------------------------------------------

-- Target simulated interval between samples: 1/120s, i.e. twice the nominal 60Hz Heartbeat. Chosen
-- as the smallest value that is unambiguously cheap at the candidate counts this engine deals with
-- (a handful of tagged combatant parts, never the whole workspace -- see CandidateGatherer), while
-- being fine enough that the residual gap the swept test has to cover is a fraction of a stud at
-- realistic swing speeds.
HitboxEngineConstants.MinSubstepSeconds = 1 / 120

-- Hard ceiling on subdivisions of a single Heartbeat. Eight substeps covers a frame of ~66ms (a 15fps
-- server) at the full sample rate; beyond that the engine degrades sample density rather than
-- amplifying the stall. See this file's header.
HitboxEngineConstants.MaxSubstepsPerFrame = 8

-- deltaTime is not bounded by the engine -- a Studio pause, a script yield or a genuine server stall
-- can deliver an arbitrarily large frame. Clamped before it drives anything so a resumed session
-- cannot fast-forward an entire attack (or fabricate a hundred-stud interpolated sweep) in one tick.
HitboxEngineConstants.MaxFrameSeconds = 0.25

-- Budgets ----------------------------------------------------------------------------------------

-- Concurrent swings the engine will sample. Each one costs a broadphase query per substep, so this
-- is the number that actually bounds the engine's worst-case frame cost. A refusal past it degrades
-- one attack in a large brawl instead of everyone's frame time.
HitboxEngineConstants.MaxActiveSwings = 64

-- Ceiling on parts one broadphase query may return. The query is already restricted to registered
-- combatant bodies (an Include filter, not an Exclude one), so reaching this means an implausible
-- crowd inside one hitbox rather than an ordinary busy scene.
HitboxEngineConstants.MaxCandidatesPerSample = 64

-- Default when an AttackDefinition does not specify MaxTargetsPerSwing.
HitboxEngineConstants.DefaultMaxTargetsPerSwing = 8

-- Absolute deadline on a single swing, whatever its authored timings sum to. A swing whose owner
-- never calls CancelAttack and whose definition carries an absurd ActiveSeconds would otherwise hold
-- one of the MaxActiveSwings slots -- and, if it locks movement, the attacker's body -- indefinitely.
HitboxEngineConstants.MaxSwingSeconds = 10

-- Geometry ---------------------------------------------------------------------------------------

-- Studs added to the broadphase volume's half-extents. The broadphase asks about part BOUNDING
-- BOXES, so it is already conservative, but the swept narrow-phase test interpolates BETWEEN this
-- sample's pose and the last one's -- and a target only inside the volume at some midpoint of that
-- interpolation must still have been GATHERED this frame to be tested at all. The margin is what
-- makes the broadphase cover the swept region rather than just its endpoint.
HitboxEngineConstants.BroadphaseMarginStuds = 2

-- Slack allowed in the exact narrow-phase test, in studs. Non-zero because a hit is judged against a
-- part's CENTRE (see HitboxEngine.sampleSwing) rather than its surface: a limb whose centre sits
-- just outside the volume while the limb itself is plainly inside it should count.
HitboxEngineConstants.NarrowPhaseMarginStuds = 0.5

-- Ceiling on interpolation steps inside one swept narrow-phase test. Distinct from
-- MaxSubstepsPerFrame: that bounds how often the world is QUERIED, this bounds how finely one
-- already-gathered candidate is tested against one already-known pair of poses. Cheap enough to be
-- generous -- it is arithmetic on a handful of candidates, no engine calls at all.
HitboxEngineConstants.MaxSweptSteps = 8

-- Scaling ----------------------------------------------------------------------------------------

-- Floor on the total scale multiplier a ScalingProfile may resolve to. A zero or negative multiplier
-- (from a hostile power level, or a combo stage authored as 0) would collapse the hitbox to nothing
-- or invert it; refusing to go below this keeps a mis-authored scale merely small rather than broken.
HitboxEngineConstants.MinScaleMultiplier = 0.05

-- Integration ------------------------------------------------------------------------------------

-- Every registered combatant model carries this CollectionService tag. It is the outward signal that
-- a model is a real, engine-known fighter -- the thing the "parkour probes treat bodies as terrain"
-- bug class needed and did not have. The engine's own hot path uses its registry table rather than
-- HasTag (an O(1) lookup it already owns), so the tag exists for OTHER systems: a future consumer
-- layer, a movement probe that wants to exclude bodies, or a debug visualiser.
HitboxEngineConstants.CombatantTag = "Combatant"

-- Humanoid Attribute set true for the duration of a LocksMovement swing's Active window, cleared when
-- that swing ends by any route (recovery, interruption, unregistration).
--
-- This is the ENTIRE integration contract between this engine and the movement framework.
-- Client/Parkour/ParkourController.lua's resolveCombatOwned already polls this exact Attribute and
-- hands the body to the AerialCombat state (priority 1000, pre-empts everything) while it is set, so
-- a locking swing parks parkour with zero parkour-side changes. Renaming it here silently unparks the
-- movement system mid-swing.
HitboxEngineConstants.RootControlLockedAttribute = "RootControlLocked"

-- Debug ------------------------------------------------------------------------------------------

HitboxEngineConstants.Debug = {
	-- Master switch for the engine's debug logging AND the volume visualiser below.
	--
	-- OFF as of the attack layer shipping. It was on while the block/parry system and the temporary
	-- test attack harness were being exercised by hand -- a swing's real hitbox being visible was the
	-- only way to tell a miss from a broken hitbox back when nothing else in the game reacted to a
	-- contact. That is no longer true: Client/Combat/CombatFeedbackClient.lua now shows the outcome of
	-- every resolved contact, and every player would otherwise see translucent red boxes flashing
	-- around every fighter, since the visualiser draws SERVER-side Parts that replicate to everyone.
	-- At 120 samples/second per swing the per-sample logging is a real cost too. Flip back on for
	-- active hitbox debugging; it is not something to leave on with real players in the server.
	Enabled = false,

	-- Logs one line per swing start/end and per hit report. Requires Enabled.
	LogSwings = true,

	-- Draws the swing's ACTUAL sampled volume as a translucent red server-side Part (HitboxEngine.lua's
	-- showDebugVolume/hideDebugVolume), reusing HitboxGeometry.BoundingBox so it can never disagree
	-- with what the engine is really testing against. A server Part rather than a client overlay: it
	-- replicates to every client for free, and the debug folder it lives in
	-- (Workspace.HitboxDebugVolumes) is excluded from the engine's own broadphase (CandidateGatherer
	-- only ever includes registered combatant models), so it cannot affect hit detection. Requires
	-- Enabled.
	DrawVolumes = true,
}

return HitboxEngineConstants
