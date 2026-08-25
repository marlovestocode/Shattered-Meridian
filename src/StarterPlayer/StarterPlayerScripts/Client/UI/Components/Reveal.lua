--!strict
--[[
	Components/Reveal.lua

	Owns: the one entrance and exit every ambient HUD tile wears -- the spring that carries it, the
	scale that makes it read as arriving rather than appearing, and the guard that keeps a leaving
	tile in the tree until it has finished leaving.

	Does NOT own: whether a tile should be on screen (its own screen decides that, and hands the
	answer in as `Visible`), where the tile sits (Shell/Regions.lua), or what the tile contains.

	Tier 3 of docs/architecture/2026-08-20-ui-velocity-plan.md and Phase 5 of the HUD shell plan. It
	replaces four different answers to one question, which is this codebase's bar for a shared
	component:

	  BlimpHelm        hand-rolled spring, ENTER_OFFSET = 14, its own 2% scale, its own exit guard
	  Announcement     Tokens.Motion.FadeSpring on transparency only -- no arrival at all, just a fade
	  BlimpFuel        nothing. It pops.
	  CarriedResources nothing. It pops.

	================================================================================================
	IT DOES NOT ANIMATE Position, AND IT CANNOT
	================================================================================================

	This is the constraint the whole component is shaped around, and it is worth stating first
	because the obvious implementation -- a 14px rise on Position, which is what two of the four
	screens above were doing -- is not merely discouraged here, it does not work.

	Every tile this component serves is laid out by its region's UIListLayout (Shell/Regions.lua).
	A UIListLayout WRITES Position on every one of its children on every layout pass. So a spring
	driving a tile's Position is overwritten between frames by the layout, and the slide either does
	not appear or appears as a fight. Phase 1 of the shell plan discovered this by losing both
	hand-rolled entrances to it, and recorded it as the one regression that phase could not avoid.

	What a laid-out tile CAN animate is anything that is not its own Position:

	  * a UIScale parented inside it -- the arrival this component leads with
	  * its own Size, which the layout reads rather than writes (all four tiles are AutomaticSize.Y,
	    so their height is content-driven and this is left alone)
	  * transparency, on whatever the caller chooses to bind it to

	A translation is still possible in principle -- a fixed-size clipping tile with a sliding child
	inside it -- and it is deliberately not what this does. Every tile here is AutomaticSize.Y over
	content whose height changes (the helm drops three rows for a passenger, the resources tile grows
	a second line), so the fixed outer box that a slide needs is exactly the thing those tiles were
	written not to have. A scale reads as arrival, costs one Instance, and does not ask four screens
	to give up content sizing for a quarter-second of motion.

	================================================================================================
	WHAT IT HANDS BACK, AND WHY IT IS VALUES RATHER THAN A WRAPPER FRAME
	================================================================================================

	The instinct is Reveal(scope, { Child = tile }) returning a wrapper. That would put a second
	Frame between every tile and its region -- six more Instances, and a second thing for
	AutomaticSize to measure through, which is the exact interaction that inflated the helm console
	to four times its content once already (see Screens/BlimpHelm/init.lua's SurfaceTexture note).

	So this returns values plus ONE Instance the caller parents itself:

	  Mounted       -> the tile's Visible. True through the whole exit, so the spring has something
	                   on screen to animate all the way out.
	  Progress      -> 0 hidden, 1 arrived. The spring itself, for a caller with its own use for it.
	  Transparency  -> 1 hidden, 0 arrived. For a border or a label that should fade in with the rest.
	  Scale         -> a UIScale, already bound, to drop into the tile's Children.

	THE ZERO-HEIGHT COLLAPSE CONTRACT (shell plan 3.2) IS SATISFIED BY Mounted ALONE, and that is
	worth saying rather than assuming. That section asks a region to drive both Visible and a height
	collapse, because it did not know whether a UIListLayout skips invisible children. Phase 1
	answered that it does. Every tile here is AutomaticSize.Y, so a tile whose Visible is false takes
	neither height nor a share of its region's padding -- the collapse is the sizing mode, not a
	second binding somebody has to remember.

	IDLE COST (shell plan 11 rule 5), STATED PRECISELY BECAUSE THE OBVIOUS CLAIM IS WRONG. The first
	draft of this header said "a Fusion Spring stops being stepped once it has settled". It does not.
	Fusion 0.3's Spring integrates every frame for the life of its scope -- the sleep that would stop
	that is a commented-out TODO in Animation/Spring.luau, right under the branch that handles it.

	What it DOES do is snap: once the remaining offset and the remaining velocity are both under its
	own 1e-5, it sets the value to the goal exactly and `update` returns false. So nothing downstream
	recomputes while a tile is sitting still -- the Mounted Computed, the Transparency Computed and
	the UIScale binding are all genuinely idle -- and what remains is a handful of arithmetic per
	spring per frame that never propagates. Four springs on the client, one per ambient tile.

	That is the honest version of VitalIcon.lua's "exactly 0 at rest" standard here, and it is
	measured rather than reasoned: Tests/UI/Reveal.spec.lua waits for the exact goal by CONDITION and
	fails if it never arrives. A flat 40-frame wait read 0.0063 -- converged to three decimal places,
	which is exactly the near-miss an "approximately equal" assertion would have swallowed.

	================================================================================================
	THE SPRING LIVES HERE, NOT IN Tokens.Motion, AND THAT IS THE ONE DELIBERATE DEVIATION
	================================================================================================

	Every other named spring in this UI is a Tokens.Motion entry, because every other one has callers
	that are not each other -- GlintSpring is read by a parry cue, IslandSpring by the armament
	island and by the dock band that fades a bead on the same value. This one has exactly one reader,
	which is this file, and four screens that reach it only THROUGH this file. A token would be a
	number two places could set and one place could use.

	The numbers are BlimpHelm's, adopted rather than re-tuned: speed 22, damping 1. Critical damping
	is not a default here, it is the requirement -- docs/ui-ux-philosophy.md's Animation Philosophy
	asks for "smooth, controlled, intentional -- never bouncy, arcade-like", and that file's own note
	says critical damping is what kept its entrance a slide rather than a bounce. Tokens.Motion's one
	under-damped spring (IslandSpring, z = 0.68) is under-damped for a stated reason that does not
	apply to a corner readout: an island being shoved out of a dock is a thing with mass, a fuel gauge
	arriving is not.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- See the header: BlimpHelm's own tuning, adopted as the shared one. Critical, never under-damped.
local SPRING_SPEED = 22
local SPRING_DAMPING = 1

-- How far under 1 the content starts. A whisper, well under anything that reads as a "pop" -- the
-- arrival is meant to be felt rather than watched, on a surface the player is glancing at during
-- live gameplay.
local DEFAULT_DEPTH = 0.02

-- When a leaving tile may stop being drawn. Not zero: a Fusion Spring approaches its goal
-- asymptotically and would keep a tile nominally mounted for a long tail of sub-pixel motion. One
-- percent of the reveal is well under a pixel of scale on the widest tile here.
local MOUNTED_EPSILON = 0.01

export type RevealProps = {
	-- Whether the tile should be on screen. Its own screen's fact; this component never writes it.
	Visible: UsedAs<boolean>,
	-- How far under 1 the content starts. Defaults to DEFAULT_DEPTH; pass 0 for a fade with no scale.
	Depth: number?,
}

export type RevealHandle = {
	-- Bind to the tile's own Visible. Stays true through the whole exit, then goes false.
	Mounted: Fusion.Computed<boolean>,
	-- 0 hidden, 1 arrived. Exactly its goal at rest.
	Progress: UsedAs<number>,
	-- 1 hidden, 0 arrived. The inverse of Progress, for a caller that fades something in.
	Transparency: Fusion.Computed<number>,
	-- Parent this into the tile's Children. Not applied for the caller, because which frame it should
	-- scale is the caller's decision -- Panel.lua puts a UIScale in Children inside its own Content
	-- wrapper, so the chrome holds still while the contents arrive, and a non-Panel tile may want it
	-- somewhere else.
	Scale: UIScale,
}

local function Reveal(scope: Scope, props: RevealProps): RevealHandle
	local depth = props.Depth or DEFAULT_DEPTH

	local progress = scope:Spring(
		scope:Computed(function(use): number
			return if use(props.Visible) then 1 else 0
		end),
		SPRING_SPEED,
		SPRING_DAMPING
	)

	return {
		-- Visible OR still travelling. The order matters on the ENTRANCE too, not just the exit: a
		-- tile that has just been asked to appear is Visible before the spring has moved at all, so
		-- reading the spring alone would drop the first frame of every arrival.
		Mounted = scope:Computed(function(use): boolean
			return use(props.Visible) or use(progress) > MOUNTED_EPSILON
		end),
		Progress = progress,
		Transparency = scope:Computed(function(use): number
			return 1 - use(progress)
		end),
		Scale = scope:New "UIScale" {
			Scale = scope:Computed(function(use): number
				return 1 - (1 - use(progress)) * depth
			end),
		} :: UIScale,
	}
end

return Reveal
