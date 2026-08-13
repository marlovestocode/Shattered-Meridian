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
	    180  WallJumping    -- kicking off a wall beats staying on it
	    160  WallRunning    -- attaching to a wall beats falling past it
	    150  Vaulting       -- clearing an obstacle beats running into it
	    145  Mantling       -- just under Vaulting: when both are viable the faster option wins
	    140  Rolling        -- a dodge beats whatever it is dodging out of
	    120  Sliding
	     90  Landing        -- entered only by Falling's explicit hand-off
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
	require(script.WallJumping),
	require(script.WallRunning),
	require(script.Vaulting),
	require(script.Mantling),
	require(script.Rolling),
	require(script.Sliding),
	require(script.Landing),
	require(script.Jumping),
	require(script.Falling),
	require(script.Sprinting),
	require(script.Walking),
	require(script.Idle),
}

return States
