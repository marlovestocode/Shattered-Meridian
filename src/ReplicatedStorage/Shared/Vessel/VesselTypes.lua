--!strict
--[[
	VesselTypes.lua

	Owns: the shapes shared by every CREWED VEHICLE in this game -- what a mount station is, what the
	mount cue every client is told about looks like, what one rung of an engine telegraph is, what one
	band of a speed-driven audio ladder is, and the two shapes a helm's contextual controls are written
	in. A blimp and a boat are the same object in every one of these respects and differ in none of
	them.

	LIFTED OUT OF Shared/Blimp/BlimpTypes.lua rather than written fresh, when the Boat layer arrived and
	needed the identical vocabulary. The rule this codebase's CLAUDE.md sets out is that a shared module
	earns its place once the pattern has been hand-written at three or more call sites -- these had been
	written once and were about to be written a second time, which is normally not enough. The exception
	is that a SECOND copy here is not a second implementation of a pattern, it is a second definition of
	one WIRE FORMAT: two systems whose MountChangedPayload drifted by a field would produce two client
	pose paths that silently disagreed about what a mount is. Duplicating a shape that crosses a remote
	is not the same risk as duplicating a helper.

	NOT A SECTION OF Shared/Types.lua, for the reason BlimpTypes' own header gives and which is if
	anything stronger here: this is the vocabulary of a REMOVABLE layer, and a layer whose types live in
	the global registry is one that cannot be removed without unpicking that registry.

	Does not own: any tunable number (each vehicle's own Constants file), the vehicle-specific shapes --
	a blimp's Lift axis and altitude band (BlimpTypes), a boat's sail rig and waterline (BoatTypes) --
	or anything about how a mount is actually performed (Server/Vessel/VesselMount.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The ONE require this file makes, and only for Types.KeybindAction in HelmPressBinding at the bottom
-- -- the same reach, for the same reason, that BlimpTypes.lua already documents.
local Types = require(ReplicatedStorage.Shared.Types)

local VesselTypes = {}

-- What a mounted player is DOING there, resolved from which tag the station part carries. The two
-- differ in exactly one respect -- a Helm feeds a steering intent, a Handhold does not -- and in
-- nothing else: both weld the body, both pose the arms, both release the same way. Adding a third kind
-- should mean adding a row to that one difference, not a second mount path.
export type StationKind = "Helm" | "Handhold"

-- One resolved station, as VesselTagging reads it off a tagged model.
export type Station = {
	Part: BasePart,
	Kind: StationKind,
}

-- Server -> ALL clients, on every mount starting and ending. Broadcast rather than fired at the two
-- interested parties because the arm pose is not the mounted player's own presentation -- it is
-- everyone else's view of them, run per-frame on each client (see Shared/Vessel/VesselArmPose.lua's
-- header on why the pose cannot be a replicated server write).
--
-- Active = false carries no other field meaningful, the same "one payload, one shape, the false case
-- just means less of it" convention GrabTypes.GrabHoldChangedPayload already uses.
--
-- ONE SHAPE FOR EVERY VEHICLE, and it deliberately says nothing about WHICH kind of vehicle the
-- station belongs to. A client that has been handed a station part can ask the world that question
-- itself (the tag is on the model above it) and the two systems' controllers already do; putting a
-- discriminator on the wire would mean every future vehicle had to be added to an enum on a payload
-- that has no use for one.
export type MountChangedPayload = {
	Character: Model,
	Active: boolean,
	Kind: StationKind?,
	Station: BasePart?,
}

-- One rung of an engine telegraph -- see Shared/Vessel/VesselSpeedLadder.lua for what a ladder of
-- these means and Shared/Blimp/BlimpConstants.SpeedStates for one authored in full.
export type Rung = {
	Id: string,
	Label: string,
	-- -1 (full astern) .. 1 (full ahead). Exactly one rung in a ladder should be 0 -- the ladder finds
	-- its own neutral by scanning for it rather than being told where it is.
	Throttle: number,
}

-- One band of a speed-driven audio ladder -- see Shared/Vessel/VesselSpeedStage.lua.
export type Stage = {
	Id: string,
	Label: string,
	EnterFraction: number,
	PlaybackSpeed: number,
	LoopVolumeScale: number,
	LoopSpeedScale: number,
}

-- The two shapes a vehicle's Controls table is written in -- what a pilot presses at a helm, per
-- device. These are CONTEXTUAL bindings, read only while this client is holding a helm, rather than
-- Types.KeybindActions: read BlimpConstants.Controls' own header for the full argument and for why
-- every gamepad value on such a table has to be conflict-free while mounted.

-- A HELD AXIS: two opposed keyboard keys, or one gamepad stick. `Gamepad` names the STICK rather than
-- a button, and only so that a legend has something to draw -- the value actually read is
-- Client/Input/Analog.Move().
export type HelmAxisBinding = {
	Positive: Enum.KeyCode,
	Negative: Enum.KeyCode,
	Gamepad: Enum.KeyCode,
}

-- AN EDGE PRESS: one input per device. Exactly one of `Keyboard`/`Action` is given -- `Action` for the
-- one control that genuinely IS a rebindable Types.KeybindAction on that device. That exclusivity is
-- the one thing the two optional fields cannot express and each vehicle's own HelmControls spec
-- asserts instead.
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

return VesselTypes
