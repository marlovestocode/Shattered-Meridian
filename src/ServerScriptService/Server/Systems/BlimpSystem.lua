--!strict
--[[
	BlimpSystem.lua

	Owns: blimps, end to end -- discovering tagged models and normalising each into one flying body,
	putting a ProximityPrompt on every station, the mount itself (the weld, the movement lock, the
	broadcast every client needs to pose the arms), the pilot's steering intake, driving every registered
	blimp once per Heartbeat, and getting everybody off safely when a life, a session or a model ends.
	Also owns the furnace prompt -- one station for both coal and water, open to anyone nearby, not
	just the pilot -- integrating Server/Blimp/BlimpFuel.lua's pure simulation into that same Heartbeat
	tick, gating the drive intent once a hull is depleted, and pushing the pilot's own FuelUpdated
	snapshot -- see this file's own registerBlimp/depositFuel/pushFuelUpdated and BlimpFuel.lua's
	header for the arithmetic this file only calls into.

	THE INPUT IS A NATIVE ProximityPrompt, which is the one place in this codebase a Roblox built-in beat
	rolling it against Client/Input/KeybindManager.lua. A hand-rolled "am I near the thing" needs a
	distance poll, an occlusion test, an on-screen affordance, a gamepad path and a touch path -- five
	things ProximityPrompt already is, and five things this codebase would then own forever for the sake
	of one interaction. The keybind system still gets its say: BlimpController sets each prompt's
	KeyboardKeyCode from the player's own Interact bind, locally, so a rebind carries here for free.

	SERVER-AUTHORITATIVE FLIGHT, and this is a deliberate departure from how this codebase drives a
	PLAYER's body. Client/Parkour and RunSystem let the owning client simulate and validate the report,
	because a player's own movement has to be frame-tight. A blimp does not: it accelerates over five
	seconds, turns over eighteen, and carries other people's bodies welded to it. So the client sends
	TWO HELD AXES ONLY (BlimpTypes.HelmInput -- rudder and elevator, never a position, never a speed),
	the server integrates them via Server/Blimp/BlimpDrive.lua, and the hull is server-network-owned
	throughout. The cost is one input round trip of latency, which is invisible against ramps that long;
	the benefit is that a tampered client can at worst hold an axis pinned, which is what holding a key
	does anyway.

	THE THROTTLE IS NOT EVEN AN AXIS -- it is a RUNG on an engine telegraph this file owns outright
	(BlimpRecord.SpeedIndex, over Shared/Blimp/BlimpConstants.SpeedStates, resolved by
	Shared/Blimp/BlimpSpeedLadder.lua). A client can send "one rung up", never "this fast". That is
	stronger than the axis contract above rather than merely different: an axis lets a client assert a
	number the server then has to police, whereas a rung delta only lets it assert that a key was
	pressed, which is the only thing it actually witnessed. It is also the input this vehicle wanted all
	along -- see that constants table's own header on why a held key is the wrong control for a setting a
	pilot chooses once and leaves alone for minutes.

	WHO IS FLYING IT IS A STATE MACHINE, NOT A PILE OF FLAGS. Server/Blimp/BlimpFlightMode.lua steps one
	BlimpTypes.HullMode per hull per tick -- Moored, Piloted, Autopilot, Landing, Grounded -- and is the
	single place that turns that mode plus the telegraph rung plus the pilot's axes into the one
	DriveIntent the integrator sees. That machine is also what makes an abandoned ship safe: an armed
	autopilot with nobody aboard is a runaway hull flying a straight line into the altitude ceiling until
	the server restarts, so after BlimpConstants.Autopilot.AbandonGraceSeconds the machine drops the
	latch, rings down All Stop and lands the hull on whatever a downward probe finds (runGroundProbe
	below is the only Instance touch in that whole path -- see its own comment on why the probe excludes
	every player's character, not just the hull).

	THE PHYSICAL HALF OF A MOUNT IS NOT IN THIS FILE. Server/Vessel/VesselMount.lua owns the station
	prompt, the server-side reach re-check, the movement lock, the weld, and the ordered release --
	everything that is about BODIES AND WELDS rather than about airships. Read its header for why a mount
	is a weld and not a constraint pair (unlike GrabSystem's hold immediately next door), which three
	seams the movement lock reuses, and why settling a released body before waking its Humanoid and
	before handing ownership back is the entire fix for "everybody who steps off a moving blimp flies
	away".

	What stayed here is everything that is about a BLIMP: ringing the telegraph down when the last person
	steps off, whether an armed autopilot survives the pilot, cutting the exhaust, and pushing a new
	pilot their first fuel snapshot. Those are four beats a shared mount primitive would have had to take
	as four callbacks, which is a worse way of writing the same code in a further-away file.

	EVERY RELEASE PATH ENDS IN ONE FUNCTION. Dismount is reached by the request remote, by death, by
	disconnect, by the character being removed, by the model being untagged or destroyed, and by the stale
	sweep. That is six ways to leave a blimp and exactly one implementation, because a mount that is torn
	down five-sixths of the way leaves a player PlatformStanding with WalkSpeed zero and no weld -- which
	is indistinguishable, from the player's side, from being frozen forever.

	Does not own: the flight arithmetic (Server/Blimp/BlimpDrive.lua), the mode machine and the
	intent resolution (Server/Blimp/BlimpFlightMode.lua), the telegraph's own rungs and clamping
	(Shared/Blimp/BlimpSpeedLadder.lua), the welding and constraint rig
	(Server/Blimp/BlimpAssembly.lua), the mount mechanics (Server/Vessel/VesselMount.lua), the authoring
	contract (Shared/Blimp/BlimpConstants.lua), tag resolution (Shared/Blimp/BlimpTagging.lua), or the
	arm pose -- which cannot live here at all, because Motor6D.Transform does not replicate
	(Shared/Vessel/VesselArmPose.lua's header explains that in full).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpSpeedLadder = require(ReplicatedStorage.Shared.Blimp.BlimpSpeedLadder)
local BlimpTagging = require(ReplicatedStorage.Shared.Blimp.BlimpTagging)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local VesselSafety = require(ReplicatedStorage.Shared.Vessel.VesselSafety)

local BlimpAssembly = require(ServerScriptService.Server.Blimp.BlimpAssembly)
local BlimpDrive = require(ServerScriptService.Server.Blimp.BlimpDrive)
local BlimpFlightMode = require(ServerScriptService.Server.Blimp.BlimpFlightMode)
local BlimpFuel = require(ServerScriptService.Server.Blimp.BlimpFuel)
local VesselMount = require(ServerScriptService.Server.Vessel.VesselMount)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local ResourceGatheringSystem = require(script.Parent.ResourceGatheringSystem)

local logger = Logger.scope("BlimpSystem")

local BlimpSystem = {}

type StationRecord = {
	Part: BasePart,
	Kind: BlimpTypes.StationKind,
	Prompt: ProximityPrompt,
	-- Resolved ONCE at registration, not per mount: the default answer costs two raycasts (see
	-- BlimpTagging.ResolveStandOffset), and it cannot change while the blimp is registered.
	StandOffset: CFrame,
	Occupant: Player?,
}

-- The furnace station -- deliberately not a StationRecord above: it carries no Occupant, Kind or
-- StandOffset, since nobody mounts here, they just move both coal and water across and walk away.
--
-- TWO PROMPTS ON THE ONE PART, in and out. See BlimpConstants.Prompt.UnloadActionText for why that
-- pairing is deliberate here and a build error anywhere else on a hull.
type FuelStationRecord = {
	Part: BasePart,
	Prompt: ProximityPrompt,
	UnloadPrompt: ProximityPrompt,
}

type BlimpRecord = {
	Model: Model,
	Assembly: BlimpAssembly.Assembly,
	Tuning: BlimpTypes.DriveTuning,
	Drive: BlimpTypes.DriveState,
	-- The pilot's two HELD axes as last received, and NOTHING ELSE -- see BlimpTypes.HelmInput on why
	-- throttle is not on this stream. Latched (the server keeps steering at whatever was last sent
	-- rather than expecting a keepalive) and neutralised on every release path.
	Helm: BlimpTypes.HelmInput,
	-- 1-based rung on BlimpConstants.SpeedStates -- the engine telegraph. THE hull's throttle, whoever
	-- (or whatever) is currently flying it: a pilot moves it with a keypress, the autopilot simply
	-- leaves it alone, and every release path that is not an armed autopilot walks it back to neutral.
	SpeedIndex: number,
	-- The autopilot LATCH, not a mode -- whether it actually does anything is BlimpFlightMode's call.
	-- Set only from the helm; cleared by that machine reaching Landing (see onHeartbeatTick's own edge
	-- handling), which is the whole "stops when nobody is aboard" half of the feature.
	AutopilotArmed: boolean,
	-- Who is flying this and what it is doing about it -- see Server/Blimp/BlimpFlightMode.lua. One
	-- value rather than an Autopilot/Landing boolean pair, for the reasons that file's header gives.
	Flight: BlimpFlightMode.State,
	-- The last downward probe's hit height in world Y, and when the next one is due. nil until a probe
	-- has actually hit something -- honestly different from "the ground is at zero", which is why
	-- BlimpFlightMode.ResolveFloor treats nil as "no floor override" rather than as a number.
	-- Only ever refreshed for a hull nobody is aboard (BlimpFlightMode.WantsGroundProbe).
	GroundY: number?,
	NextProbeAt: number,
	-- Rebuilt (not reallocated) on each probe -- see runGroundProbe on why the filter cannot just be
	-- the hull and be done with it.
	ProbeParams: RaycastParams,
	Pilot: Player?,
	Stations: { [BasePart]: StationRecord },
	-- Everybody aboard, helm and handholds alike, maintained by mount/Dismount rather than counted by
	-- walking Stations every tick. Passengers count toward it: a ship with four people hanging off the
	-- rails is not abandoned just because nobody is steering it.
	Occupants: number,
	Exhaust: { ParticleEmitter },
	-- What the exhaust is CURRENTLY set to, so the tick can write the property only on the two frames it
	-- actually changes. ParticleEmitter.Enabled replicates, so writing it every Heartbeat would put a
	-- property update for every emitter on every blimp onto the wire sixty times a second to say nothing.
	Thrusting: boolean,
	-- Fuel (Shared/Blimp/BlimpConstants.Fuel's own header). HasFuelSystem is false, and both of
	-- FuelTuning's Minimums are forced to 0, for a hull with no Furnace tag at all -- see
	-- registerBlimp's own comment on why that is what makes an untagged hull fly exactly as it did
	-- before this feature existed. The fuel system is all-or-nothing per hull, not choosable per
	-- resource -- both Coal and Water are gated together, or neither is.
	Fuel: BlimpTypes.FuelState,
	FuelTuning: BlimpTypes.FuelTuning,
	HasFuelSystem: boolean,
	FuelStation: FuelStationRecord?,
	-- The last FuelUpdated snapshot pushed to this blimp's pilot, floored to whole units -- the edge
	-- detector onHeartbeatTick compares against so a snapshot goes out only when something a player
	-- would actually notice has changed, never once per Heartbeat. nil until the first push (mount, or
	-- the first tick a pilot is aboard a fuel-gated hull).
	LastFuelPush: { CoalFloor: number, WaterFloor: number, Thrusting: boolean }?,
	-- The same edge-detector idea as LastFuelPush above, for the helm snapshot -- see
	-- BlimpConstants.Network.RemoteNames.HelmUpdated on why that push carries only discrete state.
	-- Every field in it is discrete, so unlike the fuel push there is nothing to floor first: this
	-- compares exactly.
	LastHelmPush: { Mode: BlimpTypes.HullMode, SpeedIndex: number, Autopilot: boolean, Depleted: boolean }?,
	-- Refcounted, not a plain set: a character is easily touching more than one hull part at once (a
	-- corner, a doorway), and a single TouchEnded must not clear contact while another part is still
	-- touching them. Zero and non-existent are treated identically -- onHeartbeatTick's own consumer
	-- skips both -- so this only ever holds players currently in genuine contact. See
	-- Shared/Vessel/VesselSafety.lua's own header for what this exists to let onHeartbeatTick defend
	-- against; onHullTouched/onHullTouchEnded below are the only writers.
	Contacts: { [Player]: number },
	-- Players released from THIS hull within the last ReleaseSettleSeconds, mapped to the os.clock()
	-- deadline the window expires at. Separate from Contacts above and deliberately not folded into it:
	-- a released body has no Touched contact to be refcounted BY (it was welded into this assembly, and
	-- same-assembly parts never touch each other), and the clearance lift Dismount applies means it may
	-- never land back on the deck to acquire one either -- so the contact clamp cannot see the exact
	-- moment this exists to cover. Entries expire by deadline in onHeartbeatTick; nothing else prunes it.
	Released: { [Player]: number },
	Trove: Trove.TroveInstance,
}

type MountRecord = {
	Player: Player,
	Blimp: BlimpRecord,
	Station: StationRecord,
	-- The body, the Humanoid, the root and the weld -- everything the physical half of a mount consists
	-- of, held as ONE value that Server/Vessel/VesselMount.lua produced and is the only thing allowed to
	-- take apart. Kept whole rather than spread back out across four fields here on purpose: the four
	-- have to be released together, in one specific order, and a record that lets this file reach for
	-- `Root` on its own is one where a future edit can start doing half of a release by hand.
	Binding: VesselMount.Binding,
}

-- One entry per registered blimp, and one per mounted player. Both are small (a map has a handful of
-- blimps and at most a handful of riders each), and the two are cross-linked so a release can be driven
-- from either end -- a player disconnecting knows only their own Player, a model being destroyed knows
-- only its Model, and both have to reach the same teardown.
local blimps: { [Model]: BlimpRecord } = {}
local mounts: { [Player]: MountRecord } = {}

-- This layer's binding of the shared mount primitive -- the prompt, the reach re-check, the movement
-- lock, the weld and the ordered release. Bound here rather than in its own module (the way
-- Shared/Blimp/BlimpSpeedLadder.lua is) because nothing outside this file mounts a blimp: a ladder has
-- to be the SAME one on the server and on the client's gauge, and a mounter has exactly one call site.
local mounter = VesselMount.New({
	Scope = "Blimp",
	Prompt = BlimpConstants.Prompt,
	Mount = BlimpConstants.Mount,
})

local intentRateLimiter = RateLimiter.New(BlimpConstants.Network.MaxIntentPerSecond)
local dismountRateLimiter = RateLimiter.New(BlimpConstants.Network.MaxDismountPerSecond)
-- Their own buckets rather than sharing the steering stream's, for the reason that constant's own
-- comment gives: a flooded 15Hz axis stream must never be able to eat the press that stops a ship.
local speedShiftRateLimiter = RateLimiter.New(BlimpConstants.Network.MaxSpeedShiftPerSecond)
local autopilotRateLimiter = RateLimiter.New(BlimpConstants.Network.MaxAutopilotTogglePerSecond)
local fuelTransferRateLimiter = RateLimiter.New(BlimpConstants.Network.MaxFuelTransferPerSecond)

local mountChangedRemote: RemoteEvent? = nil
local fuelUpdatedRemote: RemoteEvent? = nil
local fuelTransferRemote: RemoteEvent? = nil
local helmUpdatedRemote: RemoteEvent? = nil

local lastSweepAt = 0

-- Broadcast, not fired at the mounting player. See this file's header and BlimpArmPose.lua's: the arm
-- pose is every OTHER client's view of this body, so a payload only the two interested parties saw would
-- produce a pilot whose arms are on the wheel on their own screen and by their sides on everyone else's.
local function broadcastMountChanged(
	character: Model,
	active: boolean,
	kind: BlimpTypes.StationKind?,
	station: BasePart?
): ()
	local remote = mountChangedRemote
	if not remote then
		return
	end
	local payload: BlimpTypes.MountChangedPayload = {
		Character = character,
		Active = active,
		Kind = kind,
		Station = station,
	}
	remote:FireAllClients(payload)
end

-- FireClient to the pilot ONLY -- never a broadcast. See BlimpConstants.Network.RemoteNames.
-- FuelUpdated's own comment: this is the pilot's own instrument panel, not a fact other players need,
-- and it is not a 60Hz stream -- callers (onHeartbeatTick's edge detector, mount, depositFuel) decide
-- when a push is actually worth sending. Reads blimp.Thrusting directly rather than taking it as a
-- parameter -- every call site either just wrote that field itself (setThrusting, in onHeartbeatTick)
-- or wants whatever it was last set to (mount, depositFuel), so there is never a case where the caller
-- knows a MORE current value than the field already holds.
local function pushFuelUpdated(blimp: BlimpRecord, player: Player): ()
	local remote = fuelUpdatedRemote
	if not remote then
		return
	end
	local tuning = blimp.FuelTuning
	local payload: BlimpTypes.FuelUpdatedPayload = {
		Coal = blimp.Fuel.Coal,
		CoalCapacity = tuning.CoalCapacity,
		CoalMinimum = tuning.CoalMinimum,
		CoalBurnPerSecond = tuning.CoalBurnPerSecond,
		Water = blimp.Fuel.Water,
		WaterCapacity = tuning.WaterCapacity,
		WaterMinimum = tuning.WaterMinimum,
		WaterBurnPerSecond = tuning.WaterBurnPerSecond,
		Thrusting = blimp.Thrusting,
	}
	remote:FireClient(player, payload)
end

-- The helm snapshot, fired at EVERY player aboard this hull -- pilot and passengers alike -- and at
-- nobody else. See BlimpConstants.Network.RemoteNames.HelmUpdated for why the audience is wider than
-- FuelUpdated's and why the payload carries no continuous quantity.
--
-- Walks `mounts` rather than this blimp's own Stations, because Stations maps a part to its occupant
-- and this needs the reverse; `mounts` is small (at most one entry per player in the server) and this
-- runs on an edge, not per tick.
local function pushHelmUpdated(blimp: BlimpRecord): ()
	local remote = helmUpdatedRemote
	if not remote then
		return
	end
	if blimp.Occupants <= 0 then
		return
	end

	local rung = BlimpSpeedLadder.At(blimp.SpeedIndex)
	local payload: BlimpTypes.HelmUpdatedPayload = {
		Mode = blimp.Flight.Mode,
		SpeedIndex = blimp.SpeedIndex,
		SpeedLabel = rung.Label,
		SpeedThrottle = rung.Throttle,
		SpeedCount = BlimpSpeedLadder.Count(),
		Autopilot = blimp.AutopilotArmed,
		ForwardYawRadians = blimp.Tuning.ForwardYawRadians,
		Depleted = blimp.HasFuelSystem and BlimpFuel.IsDepleted(blimp.Fuel, blimp.FuelTuning),
	}
	for player, mountRecord in mounts do
		if mountRecord.Blimp == blimp then
			remote:FireClient(player, payload)
		end
	end
end

-- The edge detector in front of it. Every field of the payload is discrete, so this compares exactly
-- rather than flooring first the way the fuel push has to.
--
-- `force` is for the two cases where a push is owed even though nothing changed: a player mounting
-- (whose client has never seen ANY snapshot for this hull, and would otherwise wait for somebody else
-- to move the telegraph before its panel said anything at all) and a player dismounting (which
-- changes the AUDIENCE, not the state -- LastHelmPush is about the hull, and a stale one would make
-- the next boarder's own forced push look like a no-op to the detector).
local function pushHelmUpdatedIfChanged(blimp: BlimpRecord, force: boolean): ()
	local depleted = blimp.HasFuelSystem and BlimpFuel.IsDepleted(blimp.Fuel, blimp.FuelTuning)
	local last = blimp.LastHelmPush
	if
		not force
		and last
		and last.Mode == blimp.Flight.Mode
		and last.SpeedIndex == blimp.SpeedIndex
		and last.Autopilot == blimp.AutopilotArmed
		and last.Depleted == depleted
	then
		return
	end
	blimp.LastHelmPush = {
		Mode = blimp.Flight.Mode,
		SpeedIndex = blimp.SpeedIndex,
		Autopilot = blimp.AutopilotArmed,
		Depleted = depleted,
	}
	pushHelmUpdated(blimp)
end

local function setPromptEnabled(station: StationRecord, enabled: boolean): ()
	if station.Prompt.Parent then
		station.Prompt.Enabled = enabled
	end
end

-- Whether the exhaust should be burning for this intent. Forward-only by default, which is the whole of
-- BlimpConstants.Exhaust.RequiresForwardThrottle -- flip that constant and any throttle input lights it.
local function isUnderPower(intent: BlimpTypes.DriveIntent): boolean
	if BlimpConstants.Exhaust.RequiresForwardThrottle then
		return intent.Throttle > 0
	end
	return intent.Throttle ~= 0
end

-- Lights or cuts the thrust FX. Called only on a change (see BlimpRecord.Thrusting) and written on the
-- SERVER rather than pushed to clients: ParticleEmitter.Enabled is a replicated property, so one write
-- reaches everybody -- which makes this the exact opposite case from the arm pose, whose channel does not
-- replicate and therefore cannot be done here at all. Worth noticing that the two live in different
-- places for a real reason and not by accident.
local function setThrusting(blimp: BlimpRecord, thrusting: boolean): ()
	if blimp.Thrusting == thrusting then
		return
	end
	blimp.Thrusting = thrusting
	for _, emitter in blimp.Exhaust do
		if emitter.Parent then
			emitter.Enabled = thrusting
		end
	end
end

-- The ceiling a just-released (or just-separated) body's own speed is held to, for THIS hull: whatever
-- it is doing right now, plus the margin a self-propelled player could add to it. One line over
-- VesselMount's own, and it exists only so the two call sites below name a BlimpRecord rather than
-- reaching through it for an assembly root -- see BlimpConstants.Mount.ReleaseSpeedMargin for why an
-- absolute number is wrong at one end of the throttle or the other no matter where it is set.
local function releaseSpeedCeiling(blimp: BlimpRecord): number
	return mounter.ReleaseSpeedCeiling(blimp.Assembly.Root)
end

-- THE one release path -- see this file's header on why all six ways off a blimp end here. Safe to call
-- on a player who is not mounted (every caller treats it as "make sure this player is not on a blimp",
-- not something that needs its own existence check first) and safe to call on a half-destroyed character.
function BlimpSystem.Dismount(player: Player): ()
	local mount = mounts[player]
	if not mount then
		return
	end
	mounts[player] = nil

	local station = mount.Station
	if station.Occupant == player then
		station.Occupant = nil
		setPromptEnabled(station, true)
	end

	local blimp = mount.Blimp
	blimp.Occupants = math.max(0, blimp.Occupants - 1)

	-- THE LAST PERSON OFF STOPS THE SHIP, ON THIS FRAME. Not at the end of the hover window, and not
	-- via the flight machine -- immediately, here, because "I am getting off" and "the ship should
	-- stop" are the same intention and any delay between them reads as the ship ignoring you. The
	-- descent is the separate, later beat (BlimpFlightMode's own Landing transition); see
	-- BlimpConstants.Autopilot for why those two were wrong as one.
	--
	-- The latch is cleared as well as the rung, so a pilot who comes back finds a gauge that agrees
	-- with the ship: leaving autopilot armed on a hull that has already given up making way would show
	-- AUTOPILOT over a telegraph reading ALL STOP, which is two panels disagreeing about one fact.
	if blimp.Occupants <= 0 then
		blimp.AutopilotArmed = false
		blimp.SpeedIndex = BlimpSpeedLadder.NeutralIndex()
		blimp.Helm = { Steer = 0, Lift = 0 }
		setThrusting(blimp, false)
	end

	if blimp.Pilot == player then
		blimp.Pilot = nil
		-- Neutralised on release rather than left latched: a pilot who disconnects mid-turn must not
		-- leave their last steering axes driving the hull for the rest of the round.
		blimp.Helm = { Steer = 0, Lift = 0 }
		-- THE TELEGRAPH IS THE ONE THING THAT MAY SURVIVE THE PILOT, and only if they armed the
		-- autopilot before stepping away AND somebody is still aboard to be carried -- that IS the
		-- feature (BlimpConstants.Autopilot). Note the Occupants block above has already cleared the
		-- latch for an empty ship, so `AutopilotArmed` here can only still be true when there are
		-- passengers left. Without it, leaving the wheel rings down All Stop and the ship coasts to a
		-- halt over its own deceleration ramp, which is what a pilotless hull has always done.
		if not blimp.AutopilotArmed then
			blimp.SpeedIndex = BlimpSpeedLadder.NeutralIndex()
			-- Cut here rather than left to the next tick. The tick would get there within a frame, but a
			-- pilot leaving the wheel is exactly the moment somebody is looking at the exhaust, and "it
			-- went out a beat late" is the kind of thing that reads as the system being unsure. An ARMED
			-- autopilot deliberately keeps burning -- the ship is still under way.
			setThrusting(blimp, false)
		end
	end

	-- The whole physical release -- weld, clearance lift, separation velocity, ownership, movement lock --
	-- in the one strict order Server/Vessel/VesselMount.Release owns. Read that function's own comment
	-- for why settling the body BEFORE waking the Humanoid and BEFORE handing ownership back is the
	-- entire fix for "everybody who steps off a moving blimp flies away", and why doing any of the three
	-- out of order reproduces it.
	mounter.Release(mount.Binding, blimp.Assembly.Root)

	-- Armed even when the root above was already gone: the map is keyed by Player, expiry is by deadline,
	-- and a stale entry for a body that no longer exists costs one skipped iteration. See
	-- BlimpConstants.Mount.ReleaseSettleSeconds for what this window is actually for.
	blimp.Released[player] = os.clock() + BlimpConstants.Mount.ReleaseSettleSeconds

	-- The passenger's mass has left the assembly, and the weld change means Roblox has had to re-decide
	-- who owns the hull -- both have to be answered, in that order, on every mount change.
	BlimpAssembly.RefreshForceLimits(blimp.Assembly)
	BlimpAssembly.ClaimOwnership(blimp.Assembly)

	broadcastMountChanged(mount.Binding.Character, false, nil, nil)
	-- Forced: the state may not have changed at all, but the AUDIENCE has -- see
	-- pushHelmUpdatedIfChanged's own `force` comment. Sent AFTER mounts[player] was cleared, so the
	-- player who just left is not among the recipients.
	pushHelmUpdatedIfChanged(blimp, true)
	logger:debug("Dismounted", { player = player.Name, model = blimp.Model.Name })
end

local function mount(player: Player, blimp: BlimpRecord, station: StationRecord): ()
	if mounts[player] then
		return
	end
	if station.Occupant then
		return
	end

	-- The whole physical mount -- the live-rig lookup, the server-side reach re-check, the movement lock
	-- and the weld -- in Server/Vessel/VesselMount.Attach. nil means it did not happen (no live rig, or a
	-- player who walked out of reach during the round trip); both are ordinary, neither is an error, and
	-- nothing below this line has run yet, so there is nothing to unwind.
	local binding = mounter.Attach(player, station.Part, station.StandOffset)
	if not binding then
		return
	end

	station.Occupant = player
	setPromptEnabled(station, false)
	blimp.Occupants += 1
	-- Cancelled, not left to expire: a player who steps off and straight back on within the window is
	-- welded rigidly into the hull again, and clamping a member of the hull's own assembly against the
	-- hull's own speed would be the tick loop fighting the drive constraint through their body.
	blimp.Released[player] = nil
	if station.Kind == "Helm" then
		blimp.Pilot = player
		-- Zeroed on mount, not carried: whatever axes the previous pilot was holding when they let go
		-- are not a command the new one gave. The TELEGRAPH is deliberately left alone -- taking the
		-- helm of a ship already making way should not ring down All Stop under the new pilot's feet,
		-- and the rung is right there on their gauge the moment they arrive.
		blimp.Helm = { Steer = 0, Lift = 0 }
	end

	mounts[player] = {
		Player = player,
		Blimp = blimp,
		Station = station,
		Binding = binding,
	}

	BlimpAssembly.RefreshForceLimits(blimp.Assembly)
	BlimpAssembly.ClaimOwnership(blimp.Assembly)

	broadcastMountChanged(binding.Character, true, station.Kind, station.Part)
	-- Forced -- this client has never seen a snapshot for this hull, and waiting for the edge detector
	-- would leave its panel blank until somebody else moved the telegraph.
	pushHelmUpdatedIfChanged(blimp, true)

	-- THE NEW PILOT'S FIRST LOOK AT THE GAUGES, AND IT MUST COME AFTER THE MOUNT BROADCAST ABOVE.
	-- Client/Blimp/BlimpController.onFuelUpdated refuses a snapshot from a client that does not yet
	-- believe it is holding a helm, and ordering is only guaranteed WITHIN one RemoteEvent -- so a fuel
	-- push fired before MountChanged is one this pilot's own client can legitimately drop, leaving the
	-- panel blank until a whole unit of coal burns off. (It used to be fired above, next to the Pilot
	-- assignment, for exactly that reason.)
	--
	-- Pushed unconditionally rather than left to the next Heartbeat's edge detector, which would
	-- otherwise wait for that same whole unit before this pilot saw ANY reading. LastFuelPush is
	-- cleared so the detector does not then skip its own next real push by comparing against a stale
	-- value from whoever held the helm before.
	if station.Kind == "Helm" and blimp.HasFuelSystem then
		blimp.LastFuelPush = nil
		pushFuelUpdated(blimp, player)
	end
	logger:info("Mounted", { player = player.Name, model = blimp.Model.Name, kind = station.Kind })
end

-- The load half. A tap, not a hold, same as the mount prompts above -- a deposit is now literally
-- reversible (buildUnloadPrompt below is the reverse), so there is nothing to protect against by
-- making them wait.
--
-- STYLE = Custom ON BOTH FURNACE PROMPTS, which is the one property here that is not about behaviour
-- at all: it tells Roblox to draw nothing, because Client/UI/Screens/FurnacePrompt draws the pair as
-- ONE panel in this project's own visual language instead of two stock pills stacked on one part
-- (see that file's header for the full argument). Set here rather than on the client because Style is
-- a replicated property and a client writing it would be overwritten the next time this server
-- touched the prompt -- the same reasoning BlimpController.reKeyPrompt's own comment gives in
-- reverse for KeyboardKeyCode, which IS client-local and therefore belongs over there.
--
-- The interaction itself is untouched: these are still real ProximityPrompts, the engine still
-- delivers the press, and Triggered below still fires exactly as it did.
local function buildFuelPrompt(station: BasePart): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = BlimpConstants.Prompt.FuelPromptName
	prompt.ActionText = BlimpConstants.Prompt.FurnaceActionText
	prompt.ObjectText = BlimpConstants.Prompt.FurnaceObjectText
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.MaxActivationDistance = BlimpConstants.Prompt.MaxActivationDistance
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = BlimpConstants.Prompt.RequiresLineOfSight
	prompt.Parent = station
	return prompt
end

-- The unload half, and every difference from the prompt above is deliberate -- see
-- BlimpConstants.Prompt.UnloadActionText for the full argument. Its own key (two prompts on one part
-- cannot share one), its own gamepad button, and a hold rather than a tap (an accidental unload can
-- strand a fuelled hull; an accidental load cannot).
--
-- UIOffset IS STILL SET even though Style = Custom means Roblox draws neither of these. It costs
-- nothing, and it is the one property that stops the pair being illegible if the custom UI is ever
-- turned off for a build -- the fallback should be two separated pills, not two on the same pixel.
local function buildUnloadPrompt(station: BasePart): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = BlimpConstants.Prompt.UnloadPromptName
	prompt.ActionText = BlimpConstants.Prompt.UnloadActionText
	prompt.ObjectText = BlimpConstants.Prompt.FurnaceObjectText
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.MaxActivationDistance = BlimpConstants.Prompt.MaxActivationDistance
	prompt.HoldDuration = BlimpConstants.Prompt.UnloadHoldDuration
	prompt.RequiresLineOfSight = BlimpConstants.Prompt.RequiresLineOfSight
	prompt.KeyboardKeyCode = BlimpConstants.Prompt.UnloadKeyCode
	prompt.GamepadKeyCode = BlimpConstants.Prompt.UnloadGamepadKeyCode
	prompt.UIOffset = BlimpConstants.Prompt.UnloadUIOffset
	prompt.Parent = station
	return prompt
end

-- Deposits `player`'s ENTIRE carried amount of BOTH coal and water into `blimp`'s tanks in one press
-- -- the furnace is one station for both resources (BlimpConstants.Tags.Furnace's own comment), so
-- one interaction settles both, each independently capped at whatever room is left in its own tank
-- (BlimpFuel.Deposit owns that arithmetic). Open to ANYONE nearby, not just the pilot, per this
-- feature's own design: ground crew or a passenger topping off the tanks before departure is the
-- whole point of putting this prompt on the hull itself rather than gating it behind the helm. A
-- player carrying neither resource is a silent no-op -- there is nothing to warn about, a player
-- walking up out of curiosity is the common case, not a mistake.
local function pushFuelTransfer(
	player: Player,
	action: BlimpTypes.FuelTransferAction,
	outcome: BlimpTypes.FuelTransferOutcome,
	coal: number,
	water: number
): ()
	local remote = fuelTransferRemote
	if not remote then
		return
	end
	local payload: BlimpTypes.FuelTransferPayload = {
		Action = action,
		Outcome = outcome,
		Coal = coal,
		Water = water,
	}
	remote:FireClient(player, payload)
end

-- How much more of `resource` this player may carry, given what they already have. The cap belongs to
-- Shared/Blimp/BlimpConstants.Carry rather than to this System or to ResourceGatheringSystem -- see
-- that table's own header on why it lives beside the tank capacities it is tuned against. Same
-- helper shape (and the same cap) ResourceGatheringSystem.carryCapFor uses for a gather, because an
-- unload is a gather from a tank instead of from a rock and must not be able to exceed a limit a
-- mined vein already respects.
local function carryRoomFor(profile: Types.PlayerProfile, resource: BlimpTypes.FuelResource): number
	if resource == "Coal" then
		return math.max(0, BlimpConstants.Carry.CoalCap - profile.blimpFuel.Coal)
	end
	return math.max(0, BlimpConstants.Carry.WaterCap - profile.blimpFuel.Water)
end

local function depositFuel(player: Player, blimp: BlimpRecord): ()
	-- The one press this function answers with silence, deliberately -- see
	-- BlimpTypes.FuelTransferOutcome's own comment. A limited press is a duplicate of one already
	-- answered, not an outcome of its own.
	if fuelTransferRateLimiter:IsLimited(player) then
		return
	end
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		-- Also silent, and for a different reason: this is not a state the player is in, it is a state
		-- the SERVER is in (a profile that has not finished loading, or failed to). Telling them
		-- "nothing to load" would be a lie about their own pockets.
		logger:warn("Fuel deposit ignored: profile not loaded", { player = player.Name })
		return
	end

	local carriedCoal = profile.blimpFuel.Coal
	local carriedWater = profile.blimpFuel.Water
	local afterCoal, coalAccepted = BlimpFuel.Deposit(blimp.Fuel, "Coal", carriedCoal, blimp.FuelTuning)
	local afterWater, waterAccepted = BlimpFuel.Deposit(afterCoal, "Water", carriedWater, blimp.FuelTuning)
	if coalAccepted <= 0 and waterAccepted <= 0 then
		-- Nothing moved. Which of the two reasons it was decides what the player is told, and the two
		-- need different advice -- see BlimpTypes.FuelTransferOutcome. Nothing to debit off the player's
		-- own carried total either, per BlimpFuel.Deposit's own contract: accepted is 0 exactly when
		-- nothing should move on either side.
		local outcome: BlimpTypes.FuelTransferOutcome = if carriedCoal <= 0 and carriedWater <= 0
			then "NothingToMove"
			else "NoRoom"
		pushFuelTransfer(player, "Load", outcome, 0, 0)
		logger:debug("Fuel deposit moved nothing", {
			player = player.Name,
			model = blimp.Model.Name,
			outcome = outcome,
		})
		return
	end
	blimp.Fuel = afterWater

	PlayerDataSystem.Transform(player, function(mutableProfile)
		mutableProfile.blimpFuel.Coal = math.max(0, mutableProfile.blimpFuel.Coal - coalAccepted)
		mutableProfile.blimpFuel.Water = math.max(0, mutableProfile.blimpFuel.Water - waterAccepted)
	end)
	-- The one narrow seam back into ResourceGatheringSystem -- this System has no other reason to
	-- touch a player's carried total, only to debit it, so it calls that System's own public push
	-- rather than resolving/firing the remote itself (which lives, and is created, over there).
	ResourceGatheringSystem.PushCarriedFuelUpdate(player)

	-- Immediate, not left to the next Heartbeat's edge detector -- a player who just topped off the
	-- tanks for their pilot friend deserves the gauges to move the instant they let go of the prompt,
	-- not up to a frame later.
	if blimp.Pilot then
		pushFuelUpdated(blimp, blimp.Pilot)
	end

	pushFuelTransfer(player, "Load", "Moved", coalAccepted, waterAccepted)

	logger:debug("Fuel deposited", {
		player = player.Name,
		model = blimp.Model.Name,
		coalAccepted = coalAccepted,
		waterAccepted = waterAccepted,
	})
end

-- The mirror of depositFuel above: takes BOTH resources back out of `blimp`'s tanks and into
-- `player`'s own carried total, each independently capped at the room left under their carry cap
-- (BlimpConstants.Carry, via carryRoomFor). Everything the deposit path documents about audience,
-- rate limiting, and silence applies here unchanged, and the two are deliberately written as mirror
-- images so a change to one is visibly a change the other is missing.
--
-- OPEN TO ANYONE NEARBY, exactly like the deposit, and that symmetry is a decision rather than an
-- oversight: the prompt is on the hull rather than behind the helm precisely so ground crew can
-- service a ship they are not flying, and a rule that let them fill it but not correct a mistake
-- would be the more surprising of the two. The cost is real and worth stating -- a passenger CAN
-- drain a tank out from under a pilot in flight, which grounds the hull (BlimpFuel.IsDepleted). The
-- hold on the prompt (BlimpConstants.Prompt.UnloadHoldDuration) is what stops that happening by
-- accident; nothing here stops it happening on purpose. If that ever needs closing, the narrowest
-- gate is `blimp.Pilot == nil or blimp.Pilot == player` right here, NOT a new tag or a new station.
--
-- A PARTIAL TAKE IS STILL A TAKE. A player with room for 40 more coal standing at a tank holding 500
-- gets 40, and the rest stays in the tank -- the same "cap it, never refuse it" reflex
-- ResourceGatheringSystem.handleGather already applies to a gather that would overflow the cap, and
-- for the same reason: a trip that half-worked beats an all-or-nothing rejection the player had no
-- way to see coming.
local function unloadFuel(player: Player, blimp: BlimpRecord): ()
	if fuelTransferRateLimiter:IsLimited(player) then
		return
	end
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		logger:warn("Fuel unload ignored: profile not loaded", { player = player.Name })
		return
	end

	local tankCoal = blimp.Fuel.Coal
	local tankWater = blimp.Fuel.Water
	local afterCoal, coalTaken = BlimpFuel.Withdraw(blimp.Fuel, "Coal", carryRoomFor(profile, "Coal"))
	local afterWater, waterTaken = BlimpFuel.Withdraw(afterCoal, "Water", carryRoomFor(profile, "Water"))
	if coalTaken <= 0 and waterTaken <= 0 then
		-- Nothing moved, and which of the two reasons it was decides what the player is told -- see
		-- BlimpTypes.FuelTransferOutcome. An empty tank is "there is nothing in here"; a full pocket
		-- is "there is nowhere to put it", and those need different advice.
		local outcome: BlimpTypes.FuelTransferOutcome = if tankCoal <= 0 and tankWater <= 0
			then "NothingToMove"
			else "NoRoom"
		pushFuelTransfer(player, "Unload", outcome, 0, 0)
		logger:debug("Fuel unload moved nothing", {
			player = player.Name,
			model = blimp.Model.Name,
			outcome = outcome,
		})
		return
	end
	blimp.Fuel = afterWater

	PlayerDataSystem.Transform(player, function(mutableProfile)
		mutableProfile.blimpFuel.Coal += coalTaken
		mutableProfile.blimpFuel.Water += waterTaken
	end)
	-- The same narrow seam back into ResourceGatheringSystem the deposit path uses, in the other
	-- direction -- that System owns the carried total and the remote that reports it, so this one
	-- calls its public push rather than resolving the remote itself.
	ResourceGatheringSystem.PushCarriedFuelUpdate(player)

	-- Immediate, for the same reason the deposit path pushes immediately: an unload can cross a
	-- Minimum and ground the hull, and a pilot watching their own gauges should see that on the frame
	-- it happens rather than on the next edge the heartbeat detector happens to notice.
	if blimp.Pilot then
		pushFuelUpdated(blimp, blimp.Pilot)
	end

	pushFuelTransfer(player, "Unload", "Moved", coalTaken, waterTaken)

	logger:debug("Fuel unloaded", {
		player = player.Name,
		model = blimp.Model.Name,
		coalTaken = coalTaken,
		waterTaken = waterTaken,
	})
end

-- The "who" half of the fix for a player launched by holding a movement key into the hull -- see
-- VesselSafety.ClampSpeed's own header for the "why" and onHeartbeatTick's own contact-clamp loop
-- for the "when". `otherPart` is whatever touched the hull, which could be any limb of a rig, not
-- just its HumanoidRootPart -- FindFirstAncestorOfClass("Model") walks up to the character either
-- way, and a hull part or another blimp's hull touching this one resolves to a Model that owns no
-- Player, so both are filtered out for free without any extra check.
local function onHullTouched(blimp: BlimpRecord, otherPart: BasePart): ()
	local character = otherPart:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	blimp.Contacts[player] = (blimp.Contacts[player] or 0) + 1
end

local function onHullTouchEnded(blimp: BlimpRecord, otherPart: BasePart): ()
	local character = otherPart:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	local count = blimp.Contacts[player]
	if not count then
		return
	end
	if count <= 1 then
		blimp.Contacts[player] = nil
	else
		blimp.Contacts[player] = count - 1
	end
end

-- Tagged models sitting OUTSIDE the world, and the one-shot connection waiting for each to enter it.
-- Keyed by model so a re-tag cannot stack a second listener on the same one.
local pendingWorldEntry: { [Model]: RBXScriptConnection } = {}

local function cancelPendingWorldEntry(model: Model): ()
	local connection = pendingWorldEntry[model]
	if connection then
		connection:Disconnect()
		pendingWorldEntry[model] = nil
	end
end

-- Anything this System has previously built into a hull, by name. Cleared off a model before it is
-- registered -- see registerBlimp's own REGISTERING A TEMPLATE header for the state this exists to
-- survive: a template that was registered once while sitting in ServerStorage hands every clone taken
-- afterwards a full set of welds, an AlignPosition, an AlignOrientation and a live-looking set of
-- prompts, none of which are connected to anything.
--
-- Namespaced names, all four of them ours (BlimpAssembly.Build, VesselMount.BuildStationPrompt and
-- buildFuelPrompt/buildUnloadPrompt are the only things in the game that create them), so this can
-- never eat a builder's own object.
local OWNED_INSTANCE_NAMES: { [string]: boolean } = {
	BlimpHullWeld = true,
	BlimpDriveAnchor = true,
	BlimpDrivePosition = true,
	BlimpDriveOrientation = true,
	[BlimpConstants.Prompt.StationPromptName] = true,
	[BlimpConstants.Prompt.FuelPromptName] = true,
	[BlimpConstants.Prompt.UnloadPromptName] = true,
}

-- Returns how many it removed, so the caller can say something when it was not zero -- a hull arriving
-- pre-loaded with this System's own furniture is worth one log line, not silence.
local function clearInheritedInstances(model: Model): number
	local removed = 0
	for _, descendant in model:GetDescendants() do
		if OWNED_INSTANCE_NAMES[descendant.Name] then
			descendant:Destroy()
			removed += 1
		end
	end
	return removed
end

-- REGISTERING A TEMPLATE IS THE BUG THIS FUNCTION'S FIRST TWO GUARDS EXIST FOR.
--
-- CollectionService:GetTagged searches the WHOLE DataModel, not the Workspace -- so a Blimp template
-- parked in ServerStorage for Server/Systems/VehicleManager.lua to clone (which is exactly where
-- VehicleConstants requires it to live) came back from Init's own boot sweep looking like a hull, and
-- was registered as one. That produced both halves of a report that read as two unrelated bugs:
--
--   * THE HULL WOULD NOT MOVE. Registering the template welded it, unanchored it, and parented an
--     AlignPosition/AlignOrientation into its root. :Clone() copies all of that, so every spawned
--     vehicle arrived already carrying a drive constraint aimed at the TEMPLATE's position -- and
--     then got a second one of its own from its own registration. Two AlignPositions, each rated at
--     fourteen times the hull's weight, pulling toward two different places: the live one steers, the
--     inherited one holds the hull where the template was standing, and they cancel. Nothing errors.
--     Nothing logs. The blimp simply sits there with a working telegraph and a full tank.
--   * THE HELM WAS INTERMITTENT. The same clone inherited the template's ProximityPrompts, so the
--     wheel carried two prompts named BlimpPrompt, both on the Interact key. ProximityPrompt.
--     Exclusivity defaults to OnePerButton, so the engine shows exactly one of them and picks which
--     arbitrarily -- and the inherited one has no Triggered connection, because connections do not
--     survive a Clone. Half the time you mount; half the time E does nothing at all.
--
-- So: register nothing that is not actually in the world, and strip anything a model inherited from a
-- registration that happened before it got there. The second guard is not redundant with the first --
-- it is what makes a place file that was SAVED while a template was polluted recover on its own,
-- instead of shipping the damage forever.
local function registerBlimp(model: Model): ()
	if blimps[model] then
		return
	end

	if not model:IsDescendantOf(Workspace) then
		-- Not an error and not a build mistake -- this is the normal state of a VehicleManager template,
		-- and the whole point is that it stays untouched until a clone of it is standing in the world.
		-- Watched rather than dropped, so a builder who parks a tagged hull outside Workspace and drags
		-- it in at runtime still gets a blimp.
		if not pendingWorldEntry[model] then
			logger:info("Tagged model is not in the world -- not registering it until it is", {
				model = model:GetFullName(),
			})
			pendingWorldEntry[model] = model.AncestryChanged:Connect(function()
				if model:IsDescendantOf(Workspace) then
					cancelPendingWorldEntry(model)
					registerBlimp(model)
				end
			end)
		end
		return
	end
	cancelPendingWorldEntry(model)

	local inherited = clearInheritedInstances(model)
	if inherited > 0 then
		logger:warn("Hull arrived carrying this System's own instances -- stripped before building", {
			model = model:GetFullName(),
			removed = inherited,
			cause = "a template that was registered while it was still outside the world",
		})
	end

	-- Both warnings below register the blimp anyway. A hull with no stations yet is a normal state to be
	-- in while building one, and it still needs its parts welded into an assembly for the builder to see
	-- it hold together -- it simply has nowhere to stand, which the log says out loud rather than leaving
	-- as a mystery the first time somebody walks up to it and nothing happens.
	local stations, helm = BlimpTagging.ResolveStations(model)
	if #stations == 0 then
		logger:warn("Tagged model has no helm or handhold stations", { model = model:GetFullName() })
	elseif not helm then
		logger:warn("Tagged model has handholds but no helm -- nobody can steer it", {
			model = model:GetFullName(),
		})
	end

	local assembly = BlimpAssembly.Build(model)
	if not assembly then
		return
	end

	local trove = Trove.New()
	trove:Add(function()
		BlimpAssembly.Destroy(assembly)
	end)

	-- The helm's stand offset is resolved before the tuning because the BOW is derived from it -- see
	-- BlimpTagging.ResolveForwardYaw. Getting the pilot standing right is the same act as getting the
	-- blimp flying the right way, deliberately.
	local helmStandOffset = if helm then BlimpTagging.ResolveStandOffset(helm, model) else nil
	local tuning = BlimpTagging.ResolveTuning(model)
	tuning.ForwardYawRadians = BlimpTagging.ResolveForwardYaw(model, assembly.Root, helm, helmStandOffset)

	-- A blimp PARKED BELOW ITS OWN FLOOR keeps the altitude it was built at. Without this, a hull a builder
	-- moored on the ground would rise to MinAltitude the instant the server booted -- with nobody aboard,
	-- for no reason a player could see -- because the floor's whole job is to stop a PILOT descending into
	-- terrain, and it has no business hoisting a blimp nobody has touched. The ceiling is untouched: there
	-- is no equivalent case of a builder deliberately parking one above the map.
	local spawnAltitude = assembly.Root.Position.Y
	if spawnAltitude < tuning.MinAltitude then
		tuning.MinAltitude = spawnAltitude
	end

	-- An absent Furnace tag means this hull never gates on fuel at all -- see BlimpConstants.Tags.
	-- Furnace's own comment. Forcing BOTH Minimums to 0 is what actually implements "reads as
	-- unlimited": BlimpFuel.IsDepleted compares each live level against its own Minimum, and a level
	-- that can never rise above 0 (nothing can deposit into a tank the hull was never plumbed for) is
	-- never below a Minimum of 0. The fuel system is all-or-nothing per hull -- there is no "gates on
	-- coal only" hull, since both resources are loaded at the one station.
	local furnaceStation = BlimpTagging.ResolveFuelStation(model)
	local fuelTuning = BlimpTagging.ResolveFuelTuning(model)
	local hasFuelSystem = furnaceStation ~= nil
	if not hasFuelSystem then
		fuelTuning.CoalMinimum = 0
		fuelTuning.WaterMinimum = 0
	end

	local exhaust = BlimpTagging.ResolveExhaustEmitters(model)
	local exhaustWasEnabled: { [ParticleEmitter]: boolean } = {}
	for _, emitter in exhaust do
		exhaustWasEnabled[emitter] = emitter.Enabled
		-- Parked and unpowered is the state every blimp starts in, whatever the builder left the emitter
		-- checkbox on in Studio -- otherwise a blimp with nobody aboard sits there burning.
		emitter.Enabled = false
	end
	trove:Add(function()
		for emitter, wasEnabled in exhaustWasEnabled do
			if emitter.Parent then
				emitter.Enabled = wasEnabled
			end
		end
	end)

	-- Built once and mutated in place on each probe rather than constructed per cast -- see
	-- runGroundProbe on why the filter list itself still has to be rebuilt.
	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Exclude
	probeParams.IgnoreWater = false

	local record: BlimpRecord = {
		Model = model,
		Assembly = assembly,
		Tuning = tuning,
		Drive = BlimpDrive.NewState(assembly.Root.CFrame),
		Helm = { Steer = 0, Lift = 0 },
		-- Every hull is registered at All Stop, whatever the builder left it doing in Studio -- the same
		-- "parked and unpowered is the state every blimp starts in" posture the exhaust reset above
		-- takes, applied to the telegraph.
		SpeedIndex = BlimpSpeedLadder.NeutralIndex(),
		AutopilotArmed = false,
		Flight = BlimpFlightMode.NewState(),
		GroundY = nil,
		NextProbeAt = 0,
		ProbeParams = probeParams,
		Pilot = nil,
		Stations = {},
		Occupants = 0,
		Exhaust = exhaust,
		Thrusting = false,
		Fuel = BlimpFuel.NewState(),
		FuelTuning = fuelTuning,
		HasFuelSystem = hasFuelSystem,
		FuelStation = nil,
		LastFuelPush = nil,
		LastHelmPush = nil,
		Contacts = {},
		Released = {},
		Trove = trove,
	}

	-- Wired on every hull part, not just Root -- a big hull can be touched anywhere along its length,
	-- and Touched is a per-BasePart signal even though every part here moves rigidly together. See
	-- BlimpAssembly.Assembly.HullParts's own comment for why Build already hands this list back ready
	-- to use instead of registerBlimp re-deriving it.
	for _, part in assembly.HullParts do
		trove:Connect(part.Touched, function(otherPart: BasePart)
			onHullTouched(record, otherPart)
		end)
		trove:Connect(part.TouchEnded, function(otherPart: BasePart)
			onHullTouchEnded(record, otherPart)
		end)
	end

	for _, station in stations do
		local prompt = trove:Add(mounter.BuildStationPrompt(station.Part, station.Kind))
		local standOffset = if station.Part == helm and helmStandOffset
			then helmStandOffset
			else BlimpTagging.ResolveStandOffset(station.Part, model)
		local stationRecord: StationRecord = {
			Part = station.Part,
			Kind = station.Kind,
			Prompt = prompt,
			StandOffset = standOffset,
			Occupant = nil,
		}
		record.Stations[station.Part] = stationRecord
		trove:Connect(prompt.Triggered, function(player: Player)
			mount(player, record, stationRecord)
		end)
	end

	-- Open to anyone nearby, not gated behind a mount -- see depositFuel's own header.
	--
	-- BOTH WARNINGS BELOW ARE ABOUT A HULL NOBODY CAN REFUEL, which is a state this System previously
	-- registered without a word. An absent Furnace tag is legal (it means "this hull never gates on
	-- fuel" -- BlimpConstants.Tags.Furnace's own contract) and stays legal; it is logged anyway
	-- because the tag being MISSING and the tag being ABSENT ON PURPOSE look identical from in-game,
	-- and a builder who meant to place one has no other way to find out they did not.
	if furnaceStation then
		-- A furnace tagged onto a part that is ALSO a station is a build error with no visible symptom
		-- other than the one it causes: two ProximityPrompts on one part, at one distance, and
		-- ProximityPromptService shows exactly one of them. Whichever it picks, the other prompt is
		-- unreachable -- so either "Take the Helm" or "Refuel" simply does not exist on that hull, with
		-- nothing anywhere saying why. Registered anyway (the prompt is still built, and on a big
		-- enough part the two can genuinely both be reachable) -- this says out loud what to look at.
		if record.Stations[furnaceStation] then
			logger:warn(
				"Furnace is tagged on a part that is also a station; one of the two prompts will be unreachable",
				{
					model = model:GetFullName(),
					part = furnaceStation:GetFullName(),
					stationKind = record.Stations[furnaceStation].Kind,
				}
			)
		end
		local prompt = trove:Add(buildFuelPrompt(furnaceStation))
		local unloadPrompt = trove:Add(buildUnloadPrompt(furnaceStation))
		record.FuelStation = { Part = furnaceStation, Prompt = prompt, UnloadPrompt = unloadPrompt }
		trove:Connect(prompt.Triggered, function(player: Player)
			depositFuel(player, record)
		end)
		trove:Connect(unloadPrompt.Triggered, function(player: Player)
			unloadFuel(player, record)
		end)
	else
		logger:info("Blimp has no furnace; it flies unfuelled and cannot be refuelled", {
			model = model:GetFullName(),
			hint = `tag one BasePart inside it "{BlimpConstants.Tags.Furnace}" to give it a fuel system`,
		})
	end

	blimps[model] = record
	logger:info("Blimp registered", { model = model:GetFullName(), stations = #stations })
end

local function unregisterBlimp(model: Model): ()
	-- Dropped first and unconditionally: an untagged model that never made it into the world has no
	-- record here at all, only the AncestryChanged watch registerBlimp left on it, and returning early
	-- below would leak exactly that.
	cancelPendingWorldEntry(model)

	local record = blimps[model]
	if not record then
		return
	end
	blimps[model] = nil

	-- Everyone aboard comes off BEFORE the assembly is dismantled: a mount torn down after its weld's
	-- Part0 has already been restored leaves a body whose release path cannot find what it was holding.
	for player, mountRecord in mounts do
		if mountRecord.Blimp == record then
			BlimpSystem.Dismount(player)
		end
	end

	record.Trove:Clean()
	logger:info("Blimp unregistered", { model = model.Name })
end

-- Every live mount, fired at ONE client. The same payload broadcastMountChanged sends, deliberately --
-- a catch-up that differed in shape from the edge would mean two code paths on the receiving side, and
-- the second one only ever exercised by a late joiner, which is the least-tested moment there is.
local function sendExistingMounts(player: Player): ()
	local remote = mountChangedRemote
	if not remote then
		return
	end
	for _, mountRecord in mounts do
		local payload: BlimpTypes.MountChangedPayload = {
			Character = mountRecord.Binding.Character,
			Active = true,
			Kind = mountRecord.Station.Kind,
			Station = mountRecord.Station.Part,
		}
		remote:FireClient(player, payload)
	end
end

-- Resolves the blimp `player` is currently PILOTING, or nil. Shared by all three helm remotes below,
-- which had independently grown the same four-line mount lookup plus pilot check.
--
-- A passenger reaching any of them is dropped here, silently and by design: it is a legal thing for a
-- client to have in flight (they were the pilot a frame ago) rather than evidence of tampering.
local function pilotedBlimp(player: Player): BlimpRecord?
	local mountRecord = mounts[player]
	if not mountRecord then
		return nil
	end
	local blimp = mountRecord.Blimp
	if blimp.Pilot ~= player then
		return nil
	end
	return blimp
end

local function handleSetHelmInput(player: Player, raw: unknown): ()
	if intentRateLimiter:IsLimited(player) then
		return
	end
	local blimp = pilotedBlimp(player)
	if not blimp then
		return
	end

	local helm = BlimpDrive.SanitizeHelmInput(raw)
	if not helm then
		logger:debug("SetHelmInput: malformed payload ignored", { player = player.Name })
		return
	end
	blimp.Helm = helm
end

-- Moves the engine telegraph. A signed rung delta, or 0 for All Stop -- see BlimpSpeedLadder.Shift,
-- which owns both meanings and the saturation at each end.
--
-- PUSHES IMMEDIATELY rather than leaving it to the tick's own edge detector, and that is not just
-- polish: this is the one input in the whole system with no continuous consequence a player can watch.
-- Steering turns the ship within a frame; ringing down one rung on a hull that takes two and a half
-- seconds to answer shows nothing at all until the gauge moves, and a pilot who presses a key and sees
-- nothing presses it again.
local function handleShiftSpeedState(player: Player, raw: unknown): ()
	if speedShiftRateLimiter:IsLimited(player) then
		return
	end
	local blimp = pilotedBlimp(player)
	if not blimp then
		return
	end

	local delta = BlimpSpeedLadder.SanitizeDelta(raw)
	if not delta then
		logger:debug("ShiftSpeedState: malformed payload ignored", { player = player.Name })
		return
	end

	local nextIndex = BlimpSpeedLadder.Shift(blimp.SpeedIndex, delta)
	if nextIndex == blimp.SpeedIndex then
		return
	end
	blimp.SpeedIndex = nextIndex
	pushHelmUpdatedIfChanged(blimp, false)
end

-- Arms/disarms the autopilot latch. Only ever set from the helm; cleared from three other places (a
-- pilot toggling it off, the hull being abandoned long enough to reach Landing, and unregistration
-- taking the whole record with it).
local function handleToggleAutopilot(player: Player): ()
	if autopilotRateLimiter:IsLimited(player) then
		return
	end
	local blimp = pilotedBlimp(player)
	if not blimp then
		return
	end
	blimp.AutopilotArmed = not blimp.AutopilotArmed
	pushHelmUpdatedIfChanged(blimp, false)
	logger:debug("Autopilot toggled", {
		player = player.Name,
		model = blimp.Model.Name,
		armed = blimp.AutopilotArmed,
	})
end

local function handleRequestDismount(player: Player): ()
	if dismountRateLimiter:IsLimited(player) then
		return
	end
	BlimpSystem.Dismount(player)
end

-- Releases anyone whose mount has stopped being real without any of the ordinary paths firing -- a
-- character destroyed out from under the weld, a station part deleted from the Explorer mid-flight. Runs
-- on a timer rather than every tick because it exists to catch what should never happen; see
-- BlimpConstants.Mount.StaleSweepSeconds.
local function sweepStaleMounts(): ()
	for player, mountRecord in mounts do
		local stale = mountRecord.Binding.Character.Parent == nil
			or mountRecord.Binding.Humanoid.Parent == nil
			or mountRecord.Binding.Root.Parent == nil
			or mountRecord.Station.Part.Parent == nil
			or mountRecord.Binding.Humanoid.Health <= 0
			or not player.Parent
		if stale then
			logger:debug("Releasing a stale mount", { player = player.Name })
			BlimpSystem.Dismount(player)
		end
	end
end

-- Refreshes blimp.GroundY from ONE downward raycast, at most every BlimpConstants.Landing.
-- ProbeIntervalSeconds. The only reason this system ever asks what is underneath a blimp.
--
-- RUN ONLY FOR A HULL NOBODY IS ABOARD (BlimpFlightMode.WantsGroundProbe), which is what keeps this
-- off the cost sheet entirely for every blimp anybody is actually using -- and the answer is consumed
-- by nothing except a landing nobody aboard could have asked for.
--
-- THE FILTER LIST IS REBUILT EACH PROBE, not set once at registration, and it deliberately excludes
-- every player's character as well as the hull. A probe that treats a body as terrain is a recurring
-- bug class in this codebase (Client/Parkour's own casts had it), and here it lands a several-tonne
-- airship on top of whoever happened to be standing underneath it. Rebuilding a small array a couple
-- of times a second, for abandoned hulls only, is the cheap end of that trade.
local function runGroundProbe(blimp: BlimpRecord, now: number): ()
	if now < blimp.NextProbeAt then
		return
	end
	blimp.NextProbeAt = now + BlimpConstants.Landing.ProbeIntervalSeconds

	local exclude: { Instance } = { blimp.Model }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(exclude, character)
		end
	end
	blimp.ProbeParams.FilterDescendantsInstances = exclude

	local result = Workspace:Raycast(
		blimp.Assembly.Root.Position,
		Vector3.new(0, -BlimpConstants.Landing.ProbeDepthStuds, 0),
		blimp.ProbeParams
	)
	-- nil on a miss, deliberately -- see BlimpRecord.GroundY. A hull over a hole in the map has no
	-- floor to land on, and inventing zero for it would fly it down to sea level.
	blimp.GroundY = if result then result.Position.Y else nil
end

-- ONE scratch table, refilled per hull per tick, rather than a fresh literal each time. Every field
-- is overwritten below before anything reads it, and neither consumer keeps a reference:
-- BlimpFlightMode.Step is pure and returns a new State, and WantsGroundProbe only reads. At six hulls
-- on a sixty-hertz tick the literal it replaces was ~1,800 short-lived tables a second, all identical
-- in shape, all garbage by the end of the frame.
--
-- The one rule this imposes: nothing may hold onto the table it is handed. If a future consumer wants
-- to keep the context, it copies it -- reusing the scratch is the whole point, and a retained
-- reference would silently see the NEXT hull's values.
local flightContextScratch: BlimpFlightMode.Context = {
	HasPilot = false,
	OccupantCount = 0,
	AutopilotArmed = false,
	Depleted = false,
	HeightAboveGround = nil,
}

-- Piggybacks GameplayEvents.OnHeartbeatTick rather than opening a second RunService.Heartbeat connection
-- -- that signal's own header names this as the sanctioned seam for exactly this kind of per-frame work.
local function onHeartbeatTick(deltaTime: number): ()
	if next(blimps) == nil then
		return
	end

	-- Read once for the whole sweep rather than per blimp -- it feeds both the ground probe's own
	-- interval and the stale-mount sweep at the bottom, and os.clock() is not free at this cadence.
	local now = os.clock()

	for _, blimp in blimps do
		-- Checked against fuel BEFORE this tick steps it, and that same pre-tick answer decides both
		-- the drive intent below AND how much to burn this tick -- see Server/Blimp/BlimpFuel.lua's own
		-- header on why the minimum is an operating reserve rather than a literal-zero floor. Using the
		-- pre-tick reading for both keeps the two decisions from disagreeing with each other: a hull
		-- that is about to be gated never gets one more tick of "free" burn on the way down.
		local depleted = blimp.HasFuelSystem and BlimpFuel.IsDepleted(blimp.Fuel, blimp.FuelTuning)

		local context = flightContextScratch
		context.HasPilot = blimp.Pilot ~= nil
		context.OccupantCount = blimp.Occupants
		context.AutopilotArmed = blimp.AutopilotArmed
		context.Depleted = depleted
		context.HeightAboveGround = if blimp.GroundY then blimp.Assembly.Root.Position.Y - blimp.GroundY else nil

		-- Probed BEFORE the machine steps, so a hull crossing into Landing this tick already has a
		-- reading to descend against rather than spending its first frames with a nil floor.
		if BlimpFlightMode.WantsGroundProbe(context) then
			runGroundProbe(blimp, now)
		else
			-- Dropped the moment anybody boards. A stale height would otherwise sit on the record for
			-- the length of a flight and be handed to the machine as a floor the hull left behind
			-- thousands of studs ago.
			blimp.GroundY = nil
		end

		local previousMode = blimp.Flight.Mode
		blimp.Flight = BlimpFlightMode.Step(blimp.Flight, context, deltaTime)

		-- Belt and braces on the edge into Landing. Dismount has already rung the telegraph down and
		-- dropped the latch for every hull a player ever stood on, so this is normally a no-op -- it
		-- exists for the hull that reached this state without anybody ever having boarded it (spawned
		-- empty and left alone), where there is no dismount to have done it.
		if previousMode ~= "Landing" and blimp.Flight.Mode == "Landing" then
			blimp.AutopilotArmed = false
			blimp.SpeedIndex = BlimpSpeedLadder.NeutralIndex()
			logger:debug("Hull abandoned -- landing", { model = blimp.Model.Name })
		end

		-- The single place that answers "who is flying this and with what" -- see
		-- Server/Blimp/BlimpFlightMode.ResolveIntent. Note the helm axes are handed in only when there
		-- is actually a pilot: a stale axis from somebody who walked away is how a ship ends up circling.
		local intent = BlimpFlightMode.ResolveIntent(
			blimp.Flight.Mode,
			BlimpSpeedLadder.ThrottleAt(blimp.SpeedIndex),
			if blimp.Pilot then blimp.Helm else nil
		)
		local thrusting = isUnderPower(intent) and not depleted

		if blimp.HasFuelSystem then
			blimp.Fuel = BlimpFuel.Step(blimp.Fuel, thrusting, blimp.FuelTuning, deltaTime)
		end

		-- Gated AFTER the intent is resolved rather than folded into the resolution -- see
		-- BlimpFlightMode.ApplyFuelGate on why those are two different questions, and on why a descent
		-- survives depletion where thrust, steering and climb do not.
		local driveIntent = BlimpFlightMode.ApplyFuelGate(intent, depleted)
		blimp.Drive = BlimpDrive.Step(
			blimp.Drive,
			driveIntent,
			blimp.Tuning,
			deltaTime,
			BlimpFlightMode.ResolveFloor(blimp.Flight.Mode, blimp.GroundY)
		)

		-- Safety net for a hull that cannot actually move -- see BlimpDrive.ClampLead's own header. This
		-- is the only place that CAN do this: Step itself is deliberately blind to the real CFrame, so
		-- only the caller, which already reads Assembly.Root every tick to drive the constraints below,
		-- is in a position to compare Target against where the hull actually is.
		local clampedTarget =
			BlimpDrive.ClampLead(blimp.Drive.Target, blimp.Assembly.Root.Position, BlimpConstants.Drive.MaxLeadStuds)
		if clampedTarget ~= blimp.Drive.Target then
			-- Written back into Drive, not just applied to the constraint below -- otherwise Step would
			-- integrate from the UNCLAMPED Target next tick and this would hide one frame of the debt
			-- instead of actually capping it.
			blimp.Drive = {
				Target = clampedTarget,
				Speed = blimp.Drive.Speed,
				YawRate = blimp.Drive.YawRate,
				ClimbRate = blimp.Drive.ClimbRate,
			}
		end

		-- Read off `thrusting`, not off blimp.Drive.Speed -- see BlimpConstants.Exhaust. The player
		-- pressed a key; the exhaust answers on that press (or, once depleted, on the engine having
		-- nothing left to answer with), not five seconds later when the hull agrees.
		setThrusting(blimp, thrusting)
		blimp.Assembly.AlignPosition.Position = blimp.Drive.Target.Position
		blimp.Assembly.AlignOrientation.CFrame = BlimpDrive.PresentationCFrame(blimp.Drive, blimp.Tuning)

		-- Player-contact velocity safety net -- see VesselSafety.ClampSpeed's own header for why this is
		-- necessary at all and independent of everything above it in this loop: the hull's own Target
		-- debt and AlignPosition.MaxVelocity bound the HULL's speed, but a character merely TOUCHING the
		-- hull is a separate physics body that neither constraint reaches. Walked every tick rather than
		-- only from Touched -- the injection this defends against accrues gradually while contact is
		-- sustained, not just on the frame contact begins, so a player still pressed against the hull
		-- five seconds later needs to be checked on tick five just as much as tick one.
		for player, count in blimp.Contacts do
			if count <= 0 then
				continue
			end
			-- A mounted rider is welded rigidly to the hull and WalkSpeed has nothing to drive them with
			-- (see BlimpSystem.mount's own PlatformStand/RootControlLocked pair) -- skipped explicitly
			-- rather than relied on implicitly, since a stray Touched can still fire for a welded body.
			if mounts[player] then
				continue
			end
			-- RootOf, not LiveRig -- only the root is used here, and LiveRig also resolves the Humanoid
			-- (a FindFirstChildOfClass scan of the whole character) just to have it discarded on the
			-- next line. Same answer, one linear scan less per contacting player per tick.
			local character = player.Character
			local root = if character then CharacterUtil.RootOf(character) else nil
			if not root then
				continue
			end
			local velocity = root.AssemblyLinearVelocity
			local clamped = VesselSafety.ClampSpeed(velocity, BlimpConstants.Safety.MaxContactSpeed)
			if clamped ~= velocity then
				root.AssemblyLinearVelocity = clamped
			end
		end

		-- Release settle window -- a SECOND, tighter clamp on a much smaller set of players, and not a
		-- duplicate of the contact loop above it. That one is the anti-exploit backstop: a wide ceiling
		-- (MaxContactSpeed, 180) on anyone merely leaning on the hull, running for as long as they lean.
		-- This one is the separation impulse: a much tighter, hull-relative ceiling on the handful of
		-- players who stopped being PART of the hull in the last fraction of a second, and it exists
		-- because the contact loop provably cannot cover them -- see BlimpRecord.Released. The window is
		-- what makes this cheap; outside it this table is empty and the loop costs one `next`.
		for player, deadline in blimp.Released do
			if now >= deadline or mounts[player] then
				blimp.Released[player] = nil
				continue
			end
			local character = player.Character
			local root = if character then CharacterUtil.RootOf(character) else nil
			if not root then
				continue
			end
			-- Linear only, unlike VesselMount.ClampSeparatedBody's one-shot at the moment of release. The spin
			-- a body inherits FROM the hull is a single event and is already gone by here; re-zeroing every
			-- tick for three quarters of a second would instead be overwriting the player's own turning,
			-- which by this point is theirs and not the ship's.
			local velocity = root.AssemblyLinearVelocity
			local clamped = VesselSafety.ClampSpeed(velocity, releaseSpeedCeiling(blimp))
			if clamped ~= velocity then
				root.AssemblyLinearVelocity = clamped
			end
		end

		-- Pushed only on an edge a pilot would actually notice -- a whole unit of either resource
		-- burning off, or the Thrusting flag flipping (which includes the depleted transition, since
		-- `thrusting` already folds `depleted` in above) -- never once per Heartbeat. See
		-- BlimpConstants.Network.RemoteNames.FuelUpdated's own comment on why this is a snapshot, not a
		-- stream.
		if blimp.HasFuelSystem and blimp.Pilot then
			local coalFloor = math.floor(blimp.Fuel.Coal)
			local waterFloor = math.floor(blimp.Fuel.Water)
			local last = blimp.LastFuelPush
			if
				not last
				or last.CoalFloor ~= coalFloor
				or last.WaterFloor ~= waterFloor
				or last.Thrusting ~= thrusting
			then
				pushFuelUpdated(blimp, blimp.Pilot)
				blimp.LastFuelPush = { CoalFloor = coalFloor, WaterFloor = waterFloor, Thrusting = thrusting }
			end
		end

		-- The helm snapshot, on its own edge -- a mode change, a rung change, an autopilot toggle or a
		-- depleted-state flip. Cheap enough to ask every tick because the detector is four exact
		-- comparisons and the common answer is "nothing moved"; see pushHelmUpdatedIfChanged. Nothing
		-- continuous rides on it -- every client aboard is already reading this hull's speed, altitude
		-- and attitude off its own replicated physics to drive the camera.
		pushHelmUpdatedIfChanged(blimp, false)
	end

	if now - lastSweepAt >= BlimpConstants.Mount.StaleSweepSeconds then
		lastSweepAt = now
		sweepStaleMounts()
	end
end

function BlimpSystem.Init(): ()
	mountChangedRemote = NetworkBridge.CreateRemoteEvent(BlimpConstants.Network.RemoteNames.MountChanged)

	local setHelmInputRemote = NetworkBridge.CreateRemoteEvent(BlimpConstants.Network.RemoteNames.SetHelmInput)
	setHelmInputRemote.OnServerEvent:Connect(handleSetHelmInput)

	local shiftSpeedRemote = NetworkBridge.CreateRemoteEvent(BlimpConstants.Network.RemoteNames.ShiftSpeedState)
	shiftSpeedRemote.OnServerEvent:Connect(handleShiftSpeedState)

	local toggleAutopilotRemote = NetworkBridge.CreateRemoteEvent(BlimpConstants.Network.RemoteNames.ToggleAutopilot)
	toggleAutopilotRemote.OnServerEvent:Connect(handleToggleAutopilot)

	local requestDismountRemote = NetworkBridge.CreateRemoteEvent(BlimpConstants.Network.RemoteNames.RequestDismount)
	requestDismountRemote.OnServerEvent:Connect(handleRequestDismount)

	-- Server -> pilot only, never listened to server-side -- see BlimpConstants.Network.RemoteNames.
	-- FuelUpdated's own comment.
	fuelUpdatedRemote = NetworkBridge.CreateRemoteEvent(BlimpConstants.Network.RemoteNames.FuelUpdated)

	-- Server -> whichever player pressed a furnace prompt, never listened to server-side -- see
	-- BlimpConstants.Network.RemoteNames.FuelTransfer's own comment for why a silent prompt was a bug
	-- rather than a style.
	fuelTransferRemote = NetworkBridge.CreateRemoteEvent(BlimpConstants.Network.RemoteNames.FuelTransfer)

	-- Server -> everyone aboard one hull, never listened to server-side -- see
	-- BlimpConstants.Network.RemoteNames.HelmUpdated's own comment.
	helmUpdatedRemote = NetworkBridge.CreateRemoteEvent(BlimpConstants.Network.RemoteNames.HelmUpdated)

	-- Present-at-boot models and future ones through the same function, which is the whole reason
	-- GetTagged is read before the Added signal is connected rather than after: a model tagged in the
	-- window between the two would otherwise be registered twice, and registerBlimp's own guard is what
	-- makes the overlap harmless in the other direction.
	for _, tagged in CollectionService:GetTagged(BlimpConstants.Tags.Model) do
		if tagged:IsA("Model") then
			registerBlimp(tagged :: Model)
		end
	end
	CollectionService:GetInstanceAddedSignal(BlimpConstants.Tags.Model):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			registerBlimp(instance :: Model)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(BlimpConstants.Tags.Model):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			unregisterBlimp(instance :: Model)
		end
	end)

	GameplayEvents.OnHeartbeatTick(onHeartbeatTick)
	GameplayEvents.OnPlayerKilled(function(victim: Player, _killer: Player?)
		BlimpSystem.Dismount(victim)
	end)

	PlayerLifecycle.BindAllPlayers({
		Scope = "BlimpSystem",
		-- Catch-up. MountChanged is an EDGE, so a player who joins after somebody took the helm would
		-- otherwise never hear about it and would see that pilot standing at the wheel with their arms by
		-- their sides for the rest of the flight -- the pose is per-client (BlimpArmPose.lua's header),
		-- so a client that missed the edge has no other way to learn the state.
		OnPlayer = function(player: Player, _session: Trove.TroveInstance)
			sendExistingMounts(player)
		end,
		-- A new life is never mounted, and the OLD life's mount has to be released before the body it was
		-- welded to is collected -- both are this one call, on both edges.
		OnCharacterRemoving = function(player: Player, _character: Model)
			BlimpSystem.Dismount(player)
		end,
		OnPlayerRemoving = function(player: Player)
			BlimpSystem.Dismount(player)
			intentRateLimiter:Clear(player)
			dismountRateLimiter:Clear(player)
			speedShiftRateLimiter:Clear(player)
			autopilotRateLimiter:Clear(player)
			fuelTransferRateLimiter:Clear(player)
		end,
	})

	logger:info("BlimpSystem.Init() complete")
end

-- Read by nothing in the shipping game today; exists because the arm pose is client-side and a server
-- spec has no other way to assert that a mount actually produced a poseable pairing. Kept deliberately
-- narrow (a station part, not the whole record) so a future consumer cannot reach the mount's internals
-- through it.
function BlimpSystem.GetMountedStation(player: Player): (BasePart?, BlimpTypes.StationKind?)
	local mountRecord = mounts[player]
	if not mountRecord then
		return nil, nil
	end
	return mountRecord.Station.Part, mountRecord.Station.Kind
end

return BlimpSystem :: Types.SystemModule
