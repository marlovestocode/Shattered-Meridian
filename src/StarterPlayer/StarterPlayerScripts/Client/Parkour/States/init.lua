--!strict
--[[
	States/init.lua

	Owns: the registry of every movement state, and nothing else.

	THIS FILE IS THE EXTENSION POINT. Adding a movement mechanic to this game is: write one module in
	this folder implementing ParkourTypes.StateDefinition, and add one line to the list below. Nothing
	in StateMachine.lua, ParkourController.lua, ParkourMotor.lua, EnvironmentProbe.lua, the animator,
	the camera layer or the server changes -- the machine dispatches through this list, the motor
	dispatches on the state's declared Drive, the probe scheduler reads its declared Probes, the
	network layer reads its declared Reports, and the animator/debug layers key off its Id with
	documented fallbacks. That property is the design's "build the underlying architecture properly so
	new movement mechanics can be added later without having to rewrite the existing system," made
	concrete and checkable rather than asserted.

	Order in this list is presentation only -- it fixes the order the debug overlay lists states in, so
	the readout does not reshuffle between frames. Actual transition arbitration is by
	StateDefinition.Priority, which StateMachine.lua sorts on at registration; the two are listed
	together below purely so a reader can see the priority ladder in one place rather than opening
	fifteen files to reconstruct it.

	PRIORITY LADDER (highest wins a contested pre-emption):
	   1000  AerialCombat   -- combat owns the body; nothing may pre-empt it
	    220  LedgeClimbing  -- only reachable from LedgeHanging
	    210  LedgeHanging   -- catching an edge beats continuing to fall
	    176  LedgeLeaping   -- route-1 only (CanEnter always refuses); reachable exclusively from
	                       -- LedgeHanging.Update. The priority number is never consulted for
	                       -- pre-emption, and sits beside Leaping purely for a reader's convenience.
	    175  Leaping        -- the committed leap, on its own dedicated key (not a double-tap of jump any
	                       -- more -- see that state's own header). Above WallRunning, so a Leap press may
	                       -- still hijack an ordinary (non-kicking) wall-run -- but not an active kick:
	                       -- Leaping.CanEnter explicitly refuses while WallRunning's own kick phase is
	                       -- running (see that state's own "A WALL-KICK IN PROGRESS ALWAYS WINS" note).
	                       -- This used to be enforced structurally, by sitting below a separate
	                       -- WallJumping state at priority 180; kicking off a wall is now a PHASE of
	                       -- WallRunning below, not its own state -- see that file's header for why.
	    160  WallRunning    -- attaching to a wall beats falling past it, AND kicking off one (the former
	                       -- WallJumping state, now a phase of this one -- see its own header)
	    150  Vaulting       -- clearing an obstacle beats running into it
	    145  Mantling       -- just under Vaulting: when both are viable the faster option wins
	    140  Rolling        -- a dodge beats whatever it is dodging out of
	    130  Dashing        -- above Sliding so a dash may cancel one (route-2 entry needs a STRICTLY
	                       -- higher priority), and BELOW every traversal above it on purpose: Mantling,
	                       -- Vaulting, WallRunning and LedgeHanging are all meant to pre-empt a running
	                       -- dash, which is how "dash into a vault" and "air-dash onto a ledge" happen
	                       -- with those states' own CanEnter gates honoured rather than through a
	                       -- route-1 hand-off that would bypass them. See that file's header. Also
	                       -- above WallLaunching (75), which is what lets "jump at a wall, look up,
	                       -- click dash" actually chain -- Dash.AllowedFromStates names it explicitly.
	    120  Sliding
	     90  Landing        -- entered only by Falling's explicit hand-off
	     75  WallLaunching  -- one above Jumping, so a grounded jump press facing a wall too tall to
	                       -- vault/mantle resolves here instead of an ordinary jump -- see that file's
	                       -- own header for the full design.
	     70  Jumping
	     60  Falling
	     30  Sprinting
	     20  Walking
	     10  Idle

	Does not own: any behavior. Every module listed here owns its own.
]]

local ParkourTypes = require(game:GetService("ReplicatedStorage").Shared.Parkour.ParkourTypes)

local States: { ParkourTypes.StateDefinition } = {
	require(script.AerialCombat),
	require(script.LedgeClimbing),
	require(script.LedgeHanging),
	require(script.LedgeLeaping),
	require(script.Leaping),
	require(script.WallRunning),
	require(script.Vaulting),
	require(script.Mantling),
	require(script.Rolling),
	require(script.Dashing),
	require(script.Sliding),
	require(script.Landing),
	require(script.WallLaunching),
	require(script.Jumping),
	require(script.Falling),
	require(script.Sprinting),
	require(script.Walking),
	require(script.Idle),
}

return States
