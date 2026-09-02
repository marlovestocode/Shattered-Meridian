--!strict
--[[
	BlimpTypes.lua

	Owns: the shapes the Blimp layer is written in -- what a mount station is, what a pilot's steering
	intent looks like on the wire, the drive integrator's own state/tuning pair, and the mount cue
	every client is told about.

	Deliberately NOT a section of Shared/Types.lua, for the same reason GrabTypes.lua/AttackTypes.lua
	are not: this system is a module, and a module whose types live somewhere else is one that cannot
	be removed without unpicking that somewhere else.

	Does not own: the tunable numbers themselves (BlimpConstants.lua), how a tagged Model becomes one
	driveable body (Server/Blimp/BlimpAssembly.lua), or the integration itself
	(Server/Blimp/BlimpDrive.lua -- which is written entirely against DriveState/DriveIntent/DriveTuning
	below and touches no Instance at all, which is what makes it testable without a place file).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The ONE require this file makes, and only for Types.KeybindAction in HelmPressBinding at the
-- bottom. The same reach Shared/Attack/AttackTypes.lua, Shared/Kit/KitTypes.lua and
-- Shared/Bloodline/BloodlineTypes.lua already make: a per-system types module may name a type
-- from the global one, which is not the coupling this file's header refuses (that is about this
-- system's OWN types living somewhere else, where removing the system would leave them behind).
local Types = require(ReplicatedStorage.Shared.Types)

local BlimpTypes = {}

-- What a mounted player is DOING there, resolved from which tag the station part carries. The two
-- differ in exactly one respect -- a Helm feeds DriveIntent, a Handhold does not -- and in nothing
-- else: both weld the body, both pose the arms, both release the same way. Adding a third kind
-- should mean adding a row to that one difference, not a second mount path.
export type StationKind = "Helm" | "Handhold"

-- Client -> server, from the pilot only, at BlimpConstants.Network.IntentSendHz. Every field is an
-- AXIS, not a speed: the client says "full ahead", never "move me 34 studs". That is what keeps the
-- server the only thing that knows how fast this blimp can actually go, and it is why a tampered
-- client can at worst hold an axis pinned -- something a player holding W does anyway.
export type DriveIntent = {
	Throttle: number, -- -1 (full astern) .. 1 (full ahead)
	Steer: number, -- -1 (port) .. 1 (starboard)
	Lift: number, -- -1 (descend) .. 1 (climb)
}

-- What the pilot's client actually SENDS, at BlimpConstants.Network.IntentSendHz. A strict subset of
-- DriveIntent above, and the subset is the point: throttle is a telegraph rung the server owns (see
-- BlimpConstants.SpeedStates), moved by its own edge remote, so it is not on this stream at all.
--
-- Two types rather than one with an optional field, because they answer different questions and have
-- different authorities. DriveIntent is what the INTEGRATOR consumes -- three axes, all three
-- meaningful, assembled server-side from a rung plus this. HelmInput is what a CLIENT is allowed to
-- assert -- and a client asserting a speed is exactly what this system has never let one do.
export type HelmInput = {
	Steer: number, -- -1 (port) .. 1 (starboard)
	Lift: number, -- -1 (descend) .. 1 (climb)
}

-- What the hull is DOING with itself, as decided once per tick by Server/Blimp/BlimpFlightMode.lua.
-- One value, five states, and every one of them is a different answer to "who is flying this":
--
--   Moored    -- nobody is flying it and nothing is latched. Coasts down its own deceleration ramp
--                and then sits there holding altitude. Covers three situations that want identical
--                behaviour: a hull with people aboard and nobody at the wheel, a freshly registered
--                hull, and -- the case that matters most -- a hull everybody has just stepped off,
--                for the whole hover window before it starts coming down. See
--                BlimpConstants.Autopilot on why stopping and landing are two separate beats.
--   Piloted   -- a player is holding the helm. The ordinary case, and the only one where a human's
--                keys reach the integrator.
--   Autopilot -- the helm is empty, somebody is still aboard, and the telegraph rung is latched. See
--                BlimpConstants.Autopilot.
--   Landing   -- nobody has been aboard for the abandon grace. Descending onto whatever the ground
--                probe found, ignoring the normal altitude floor. Not a player-reachable mode.
--   Grounded  -- landing finished and settled. Holds station at touchdown height until somebody
--                mounts, which returns it to Moored/Piloted on the very next tick.
--
-- A STRING UNION RATHER THAN A SET OF BOOLEANS, and that is load-bearing rather than stylistic. The
-- first sketch of this had `Autopilot: boolean` and `Landing: boolean` on the record, which admits
-- "landing while on autopilot" and "neither, with nobody aboard" -- two states that mean nothing and
-- that every reader would then have to independently decide how to handle. One value cannot be in
-- two modes, so nobody downstream has to.
export type HullMode = "Moored" | "Piloted" | "Autopilot" | "Landing" | "Grounded"

-- Server -> every player aboard ONE hull, on an edge. See BlimpConstants.Network.RemoteNames.
-- HelmUpdated's own comment for why passengers get this when they do not get FuelUpdated, and for why
-- there is not a single continuous quantity in here.
export type HelmUpdatedPayload = {
	Mode: HullMode,
	-- 1-based index into BlimpConstants.SpeedStates. Sent alongside its own Label rather than leaving
	-- the client to index that table itself: the client would get the same answer today, but the day a
	-- hull carries a bespoke ladder the index alone stops being enough and the failure is a WRONG word
	-- on the gauge, not a missing one.
	SpeedIndex: number,
	SpeedLabel: string,
	-- The rung's own throttle fraction, -1..1 -- what the gauge fills to, and what tells it which side
	-- of All Stop this rung sits on without re-deriving it from the index.
	SpeedThrottle: number,
	SpeedCount: number,
	Autopilot: boolean,
	-- This hull's resolved bow correction, in radians (BlimpTagging.ResolveForwardYaw). Constant for
	-- the life of a registration, which is exactly why it can ride a discrete edge push instead of
	-- forcing a continuous one.
	--
	-- SENT RATHER THAN RE-RESOLVED CLIENT-SIDE, even though BlimpTagging is a Shared module the client
	-- could call itself. That resolution ends in two downward raycasts against the deck under the helm
	-- (ResolveStandOffset), and a client is streaming: the deck part may simply not be loaded on the
	-- frame a player boards, so the client would silently resolve a DIFFERENT bow from the server and
	-- draw a compass that disagreed with the direction the ship visibly travels. One number on one
	-- packet buys agreement outright.
	ForwardYawRadians: number,
	-- Whether the engine is currently fuel-gated. Already implied by Mode for a hull nobody is flying,
	-- but a PILOTED hull can be depleted too, and a pilot whose telegraph says FLANK while the ship
	-- sits still deserves to be told which of the two facts is winning.
	Depleted: boolean,
}

-- The integrator's whole world. Target is the pose the drive constraints are CHASING, not the pose
-- the blimp is in -- the gap between the two is the entire reason this reads as a heavy floating
-- thing rather than a brick on rails, and nothing here ever reads the blimp's real CFrame back (see
-- BlimpDrive.lua's header on why closing that loop would fight the constraints instead of helping).
--
-- Target is deliberately kept UPRIGHT (yaw only, no roll). The visible bank is derived from YawRate
-- at presentation time by BlimpDrive.PresentationCFrame, so a turn that ends leaves no accumulated
-- roll to unwind and a blimp that is nudged by a physics collision cannot bank itself into the sea.
export type DriveState = {
	Target: CFrame,
	Speed: number,
	YawRate: number,
	ClimbRate: number,
}

export type DriveTuning = {
	-- Which way is BOW, as a yaw offset in radians from the root part's own LookVector.
	--
	-- This exists because a root part's orientation is arbitrary geometry, not a designed direction: a
	-- balloon mesh's -Z axis is wherever the modeller happened to leave it, and reading travel direction
	-- straight off it gives a blimp that flies backwards through no fault of the builder's. Resolved once
	-- at registration by BlimpTagging.ResolveForwardYaw; see that function for the two ways to author it.
	ForwardYawRadians: number,
	CruiseSpeed: number,
	ReverseSpeed: number,
	Acceleration: number,
	TurnRate: number,
	TurnAcceleration: number,
	ClimbSpeed: number,
	ClimbAcceleration: number,
	BankRadiansPerTurnRate: number,
	MinAltitude: number,
	MaxAltitude: number,
}

-- Which pool a deposit/gather touches. A string union rather than two separate functions
-- (DepositCoal/DepositWater) because BlimpSystem.depositFuel and ResourceGatheringSystem both drive
-- this off a station's/node's own tag/config, so the caller already has "which resource" as a value,
-- not as a choice between two code paths to write out by hand.
export type FuelResource = "Coal" | "Water"

-- One blimp's fuel pool. Lives on BlimpRecord, not on the player -- fuel belongs to the hull, the
-- same way Drive/Intent do. Seeded at { Coal = 0, Water = 0 } on registration (Server/Systems/
-- BlimpSystem.registerBlimp): a freshly spawned blimp is unfueled, matching "users have to collect
-- these items to use the blimp."
export type FuelState = {
	Coal: number,
	Water: number,
}

-- This blimp's fuel tuning: BlimpConstants.Fuel, with any per-model Attribute overrides applied by
-- BlimpTagging.ResolveFuelTuning -- same shape and same reasoning as DriveTuning above. Minimum is
-- an OPERATING RESERVE, not a depletion floor -- see BlimpConstants.Fuel's own header and
-- Server/Blimp/BlimpFuel.IsDepleted, which compares against these, never against zero.
export type FuelTuning = {
	CoalCapacity: number,
	WaterCapacity: number,
	CoalMinimum: number,
	WaterMinimum: number,
	CoalBurnPerSecond: number,
	WaterBurnPerSecond: number,
}

-- Server -> the pilot only (FireClient), on mount/deposit/a depleted-state edge/a whole-unit change.
-- Carries each Minimum alongside the raw levels because the CLIENT computes its own time-to-cutoff
-- and status color locally (Client/UI/Screens/BlimpFuel/init.lua) rather than being pushed a
-- pre-computed string every frame -- see BlimpConstants.Network.RemoteNames.FuelUpdated's own
-- comment for why this is a snapshot, not a stream.
export type FuelUpdatedPayload = {
	Coal: number,
	CoalCapacity: number,
	CoalMinimum: number,
	CoalBurnPerSecond: number,
	Water: number,
	WaterCapacity: number,
	WaterMinimum: number,
	WaterBurnPerSecond: number,
	-- Whether the engine is currently drawing on the pool -- the client only extrapolates a resource
	-- downward locally while this is true, and treats "not thrusting" as "not draining" exactly like
	-- the server does.
	Thrusting: boolean,
}

-- Which way fuel moved at the furnace. The two prompts on that station are mirror images of one
-- another -- BlimpConstants.Prompt.UnloadActionText -- so they share one payload and one client
-- handler, with this saying which of them the player pressed.
export type FuelTransferAction = "Load" | "Unload"

-- What one press of either furnace prompt did. Three outcomes rather than a boolean because the two
-- FAILURES are not the same failure and a player cannot act on the same advice for both. Loading:
-- NothingToMove means "your pockets are empty, go and gather", NoRoom means "this hull is already
-- fuelled". Unloading: NothingToMove means "this tank is empty", NoRoom means "your own carry cap is
-- full". Collapsing them into "it didn't work" would reproduce, in words, the silence this whole
-- payload replaces.
--
-- SAID FROM THE PLAYER'S SIDE, WHICHEVER WAY THE FUEL WENT -- "there is nothing to move" and "there
-- is nowhere to put it" are true statements about a load and an unload alike, which is what lets one
-- pair of names cover both without either reading backwards.
--
-- A rate-limited press reports NOTHING at all -- it is not an outcome, it is the same press arriving
-- twice, and answering it would put a toast on screen for an interaction the player only performed
-- once.
export type FuelTransferOutcome = "Moved" | "NothingToMove" | "NoRoom"

-- Server -> the player who pressed the prompt only. See
-- BlimpConstants.Network.RemoteNames.FuelTransfer. Coal/Water are what actually CROSSED -- never
-- what either side was holding -- and either can be 0 on a "Moved" outcome (a hull whose coal bin is
-- full still takes the water), so the client renders only the halves that really moved.
export type FuelTransferPayload = {
	Action: FuelTransferAction,
	Outcome: FuelTransferOutcome,
	Coal: number,
	Water: number,
}

-- Server -> ALL clients, on every mount starting and ending. Broadcast rather than fired at the two
-- interested parties because the arm pose is not the mounted player's own presentation -- it is
-- everyone else's view of them, run per-frame on each client (see Shared/Blimp/BlimpArmPose.lua's
-- header on why the pose cannot be a replicated server write).
--
-- Active = false carries no other field meaningful, the same "one payload, one shape, the false case
-- just means less of it" convention GrabTypes.GrabHoldChangedPayload already uses.
export type MountChangedPayload = {
	Character: Model,
	Active: boolean,
	Kind: StationKind?,
	Station: BasePart?,
}

-- The two shapes BlimpConstants.Controls is written in -- what a pilot presses at a helm, per
-- device. Read that table's own header for why these bindings are contextual data rather than
-- Types.KeybindActions, and for the conflict argument behind every gamepad value in it.

-- A HELD AXIS: two opposed keyboard keys, or one gamepad stick. `Gamepad` names the STICK rather than
-- a button, and only so that a legend has something to draw -- the value actually read is
-- Client/Input/Analog.Move(), whose X is the rudder and whose Y is the elevator.
export type HelmAxisBinding = {
	Positive: Enum.KeyCode,
	Negative: Enum.KeyCode,
	Gamepad: Enum.KeyCode,
}

-- AN EDGE PRESS: one input per device. Exactly one of `Keyboard`/`Action` is given -- `Action` for the
-- one control that genuinely IS a rebindable Types.KeybindAction on that device (see
-- BlimpConstants.Controls.Release). That exclusivity is the one thing the two optional fields cannot
-- express and Tests/Blimp/BlimpHelmControls.spec.lua asserts instead.
--
-- `Gamepad` IS REQUIRED WHERE Client/Input/Glyph.lua's OWN Binding MAKES IT OPTIONAL, which is the
-- only difference between the two shapes. A general binding may legitimately name one device and not
-- the other; a helm control may not, because a control with no gamepad button is a control a
-- controller player cannot reach at a wheel they are welded to.
export type HelmPressBinding = {
	Keyboard: Enum.KeyCode?,
	Action: Types.KeybindAction?,
	Gamepad: Enum.KeyCode,
}

return BlimpTypes
