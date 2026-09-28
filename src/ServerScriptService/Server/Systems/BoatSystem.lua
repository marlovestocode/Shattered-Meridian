--!strict
--[[
	BoatSystem.lua

	Owns: boats, end to end -- discovering tagged models and normalising each into one driveable body,
	putting a ProximityPrompt on every station, the mount, the helmsman's rudder intake, the sail rung,
	sailing every registered boat once per Heartbeat against the wind and the water, and getting
	everybody off safely when a life, a session or a model ends.

	THE PHYSICAL HALF OF A MOUNT IS NOT IN THIS FILE. Server/Vessel/VesselMount.lua owns the station
	prompt, the server-side reach re-check, the movement lock, the weld and the ordered release -- read
	its header for why a mount is a weld and not a constraint pair, and why settling a released body
	before waking its Humanoid and before handing ownership back is the entire fix for "everybody who
	steps off a moving boat flies away". What stays here is what is about a BOAT: furling her sails when
	the last person steps off, whether a latched Adrift setting survives the skipper, and the wake.

	SERVER-AUTHORITATIVE SAILING, and this is a deliberate departure from how this codebase drives a
	PLAYER's body. Client/Parkour and RunSystem let the owning client simulate and validate the report,
	because a player's own movement has to be frame-tight. A boat does not: she accelerates over seven
	seconds, turns over eleven, and carries other people's bodies welded to her. So the client sends ONE
	HELD AXIS (BoatTypes.HelmInput -- the rudder, never a position, never a speed), the server integrates
	it via Server/Boat/BoatDrive.lua, and the hull is server-network-owned throughout. The cost is one
	input round trip of latency, invisible against ramps that long; the benefit is that a tampered client
	can at worst hold the helm over, which is what holding a key does anyway.

	THE SAIL SETTING IS NOT EVEN AN AXIS -- it is a RUNG this file owns outright (BoatRecord.SailIndex,
	over BoatConstants.SailStates, resolved by Shared/Boat/BoatSailLadder.lua). A client can send "one
	notch more canvas", never "this much". That is stronger than the axis contract above rather than
	merely different: an axis lets a client assert a number the server then has to police, whereas a rung
	delta only lets it assert that a key was pressed, which is the only thing it actually witnessed.

	AND THE RUNG IS NOT THE SPEED, which is the whole difference between this System and BlimpSystem. A
	blimp's telegraph rung IS its throttle; a boat's rung is canvas, and what it produces depends on the
	wind's strength and on the angle she is holding to it (Shared/Boat/BoatWind.lua). Full sail into the
	wind is zero knots. That is the mechanic, not a bug, and it is the reason a player has to read the
	weather rather than hold W.

	THE WIND AND THE SWELL ARE NEVER SENT. Both are pure functions of Workspace:GetServerTimeNow(), so
	this server sails by them and every client computes the identical values for its own vane and camera.
	See BoatConstants.Wind's header, and BoatConstants.Network.RemoteNames.HelmUpdated on why that
	omission is the same discipline that keeps a blimp's speed off its own helm packet.

	WHO IS SAILING IT IS A STATE MACHINE, NOT A PILE OF FLAGS. Server/Boat/BoatHullMode.lua steps one
	BoatTypes.HullMode per hull per tick -- Moored, Piloted, Adrift, Anchored, Beached -- and is the
	single place that turns that mode plus the rung plus the pilot's rudder into the one DriveIntent the
	integrator sees. That machine is also what makes an abandoned boat safe: a latched sail setting with
	nobody aboard is a runaway hull reaching for the edge of the map until the server restarts, so after
	BoatConstants.Adrift.AbandonGraceSeconds the machine drops the latch and furls her.

	EVERY RELEASE PATH ENDS IN ONE FUNCTION. Dismount is reached by the request remote, by death, by
	disconnect, by the character being removed, by the model being untagged or destroyed, and by the
	stale sweep. That is six ways to leave a boat and exactly one implementation, because a mount that is
	torn down five-sixths of the way leaves a player PlatformStanding with no weld -- which is
	indistinguishable, from the player's side, from being frozen forever.

	Does not own: the sailing arithmetic (Server/Boat/BoatDrive.lua), the mode machine
	(Server/Boat/BoatHullMode.lua), the water (Server/Boat/BoatWater.lua), the wind
	(Shared/Boat/BoatWind.lua), the sail ladder (Shared/Boat/BoatSailLadder.lua), the welding and
	constraint rig (Server/Boat/BoatAssembly.lua), the mount mechanics (Server/Vessel/VesselMount.lua),
	the authoring contract (Shared/Boat/BoatConstants.lua), tag resolution (Shared/Boat/BoatTagging.lua),
	or the arm pose -- which cannot live here at all, because Motor6D.Transform does not replicate
	(Shared/Vessel/VesselArmPose.lua's header explains that in full).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatSailLadder = require(ReplicatedStorage.Shared.Boat.BoatSailLadder)
local BoatTagging = require(ReplicatedStorage.Shared.Boat.BoatTagging)
local BoatTypes = require(ReplicatedStorage.Shared.Boat.BoatTypes)
local BoatWind = require(ReplicatedStorage.Shared.Boat.BoatWind)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local VesselSafety = require(ReplicatedStorage.Shared.Vessel.VesselSafety)
local VesselTypes = require(ReplicatedStorage.Shared.Vessel.VesselTypes)

local BoatAssembly = require(ServerScriptService.Server.Boat.BoatAssembly)
local BoatDrive = require(ServerScriptService.Server.Boat.BoatDrive)
local BoatHullMode = require(ServerScriptService.Server.Boat.BoatHullMode)
local BoatWater = require(ServerScriptService.Server.Boat.BoatWater)
local VesselMount = require(ServerScriptService.Server.Vessel.VesselMount)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)

local logger = Logger.scope("BoatSystem")

local BoatSystem = {}

type StationRecord = {
	Part: BasePart,
	Kind: VesselTypes.StationKind,
	Prompt: ProximityPrompt,
	-- Resolved ONCE at registration, not per mount: the default answer costs two raycasts (see
	-- VesselTagging.ResolveStandOffset), and it cannot change while the boat is registered.
	StandOffset: CFrame,
	Occupant: Player?,
}

type BoatRecord = {
	Model: Model,
	Assembly: BoatAssembly.Assembly,
	Tuning: BoatTypes.DriveTuning,
	Drive: BoatTypes.DriveState,
	-- The pilot's ONE held axis as last received. Latched (the server keeps steering at whatever was
	-- last sent rather than expecting a keepalive) and centred on every release path.
	Helm: BoatTypes.HelmInput,
	-- 1-based rung on BoatConstants.SailStates. THE hull's canvas, whoever (or whatever) is currently
	-- sailing her: a pilot moves it with a keypress, Adrift simply leaves it alone, and every release
	-- path that is not an armed Adrift furls her.
	SailIndex: number,
	-- The Adrift LATCH, not a mode -- whether it actually does anything is BoatHullMode's call. Set only
	-- from the helm; cleared by that machine reaching Anchored, which is the whole "stops when nobody is
	-- aboard" half of the feature.
	AdriftArmed: boolean,
	Hull: BoatHullMode.State,
	Pilot: Player?,
	Stations: { [BasePart]: StationRecord },
	-- Everybody aboard, helm and handholds alike, maintained by mount/Dismount rather than counted by
	-- walking Stations every tick.
	Occupants: number,
	Wake: { ParticleEmitter },
	-- What the wake is CURRENTLY set to, so the tick writes the property only on the two frames it
	-- actually changes. ParticleEmitter.Enabled replicates, so writing it every Heartbeat would put a
	-- property update for every emitter on every boat onto the wire sixty times a second to say nothing.
	Making: boolean,
	-- The last HelmUpdated snapshot pushed to this boat's occupants -- the edge detector onHeartbeatTick
	-- compares against so a snapshot goes out only when something a player would actually notice has
	-- changed. Every field in it is discrete, so unlike a continuous quantity there is nothing to floor
	-- first: this compares exactly.
	LastHelmPush: { Mode: BoatTypes.HullMode, SailIndex: number, Adrift: boolean }?,
	-- Refcounted, not a plain set: a character is easily touching more than one hull part at once (a
	-- corner, a hatchway), and a single TouchEnded must not clear contact while another part is still
	-- touching them. See Shared/Vessel/VesselSafety.lua's own header for what this exists to let
	-- onHeartbeatTick defend against.
	Contacts: { [Player]: number },
	-- Players released from THIS hull within the last ReleaseSettleSeconds, mapped to the os.clock()
	-- deadline the window expires at. Separate from Contacts and deliberately not folded into it: a
	-- released body has no Touched contact to be refcounted BY (it was welded into this assembly, and
	-- same-assembly parts never touch each other), so the contact clamp cannot see the exact moment this
	-- exists to cover.
	Released: { [Player]: number },
	Trove: Trove.TroveInstance,
}

type MountRecord = {
	Player: Player,
	Boat: BoatRecord,
	Station: StationRecord,
	-- The body, the Humanoid, the root and the weld as ONE value that Server/Vessel/VesselMount.lua
	-- produced and is the only thing allowed to take apart -- see BlimpSystem's own MountRecord for why
	-- these are not spread back out into four fields here.
	Binding: VesselMount.Binding,
}

local boats: { [Model]: BoatRecord } = {}
local mounts: { [Player]: MountRecord } = {}

-- This layer's binding of the shared mount primitive. Bound here rather than in its own module (the way
-- Shared/Boat/BoatSailLadder.lua is) because nothing outside this file mounts a boat: a ladder has to be
-- the SAME one on the server and on the client's gauge, and a mounter has exactly one call site.
local mounter = VesselMount.New({
	Scope = "Boat",
	Prompt = BoatConstants.Prompt,
	Mount = BoatConstants.Mount,
})

local intentRateLimiter = RateLimiter.New(BoatConstants.Network.MaxIntentPerSecond)
local dismountRateLimiter = RateLimiter.New(BoatConstants.Network.MaxDismountPerSecond)
-- Their own buckets rather than sharing the steering stream's: a flooded 15Hz axis stream must never be
-- able to eat the press that furls a ship or the one that gets a player off her.
local sailShiftRateLimiter = RateLimiter.New(BoatConstants.Network.MaxSailShiftPerSecond)
local adriftRateLimiter = RateLimiter.New(BoatConstants.Network.MaxAdriftTogglePerSecond)

local mountChangedRemote: RemoteEvent? = nil
local helmUpdatedRemote: RemoteEvent? = nil

local lastSweepAt = 0

-- Broadcast, not fired at the mounting player. See Shared/Vessel/VesselArmPose.lua's header: the arm
-- pose is every OTHER client's view of this body, so a payload only the two interested parties saw would
-- produce a helmsman whose hands are on the wheel on their own screen and by their sides on everyone
-- else's.
local function broadcastMountChanged(
	character: Model,
	active: boolean,
	kind: VesselTypes.StationKind?,
	station: BasePart?
): ()
	local remote = mountChangedRemote
	if not remote then
		return
	end
	local payload: VesselTypes.MountChangedPayload = {
		Character = character,
		Active = active,
		Kind = kind,
		Station = station,
	}
	remote:FireAllClients(payload)
end

-- FireClient to EVERY occupant of this hull -- helm and handholds alike. See
-- BoatConstants.Network.RemoteNames.HelmUpdated on why passengers are in the audience and why nothing
-- continuous rides on this packet.
local function pushHelmUpdated(boat: BoatRecord): ()
	local remote = helmUpdatedRemote
	if not remote then
		return
	end

	local rung = BoatSailLadder.At(boat.SailIndex)
	local payload: BoatTypes.HelmUpdatedPayload = {
		Mode = boat.Hull.Mode,
		SailIndex = boat.SailIndex,
		SailLabel = rung.Label,
		SailFraction = rung.Throttle,
		SailCount = BoatSailLadder.Count(),
		Adrift = boat.AdriftArmed,
		ForwardYawRadians = boat.Tuning.ForwardYawRadians,
	}

	for _, mountRecord in mounts do
		if mountRecord.Boat == boat then
			remote:FireClient(mountRecord.Player, payload)
		end
	end
end

-- Pushes only when something a player would notice has changed. `force` is for the two moments the
-- STATE may not have moved but the AUDIENCE has -- a mount and a dismount -- where the edge detector
-- alone would leave a new arrival's panel blank until somebody else touched the sails.
local function pushHelmUpdatedIfChanged(boat: BoatRecord, force: boolean): ()
	local last = boat.LastHelmPush
	local changed = force
		or last == nil
		or last.Mode ~= boat.Hull.Mode
		or last.SailIndex ~= boat.SailIndex
		or last.Adrift ~= boat.AdriftArmed
	if not changed then
		return
	end
	boat.LastHelmPush = {
		Mode = boat.Hull.Mode,
		SailIndex = boat.SailIndex,
		Adrift = boat.AdriftArmed,
	}
	pushHelmUpdated(boat)
end

local function setPromptEnabled(station: StationRecord, enabled: boolean): ()
	if station.Prompt.Parent then
		station.Prompt.Enabled = enabled
	end
end

-- Lights or cuts the wake. Called only on a change (see BoatRecord.Making) and written on the SERVER
-- rather than pushed to clients: ParticleEmitter.Enabled is a replicated property, so one write reaches
-- everybody -- the exact opposite case from the arm pose, whose channel does not replicate and
-- therefore cannot be done here at all.
--
-- GATED ON SPEED, NOT ON MODE, and that is the whole of BoatConstants.Wake. A hull that has lost her
-- way but is still nominally Piloted should not be throwing spray, and one carrying her way off after
-- the sails came in should -- right up until she actually stops.
local function setMakingWay(boat: BoatRecord, making: boolean): ()
	if boat.Making == making then
		return
	end
	boat.Making = making
	for _, emitter in boat.Wake do
		if emitter.Parent then
			emitter.Enabled = making
		end
	end
end

-- The ceiling a just-released (or just-separated) body's own speed is held to, for THIS hull. One line
-- over VesselMount's own, so the two call sites below can name a BoatRecord rather than reaching through
-- it for an assembly root.
local function releaseSpeedCeiling(boat: BoatRecord): number
	return mounter.ReleaseSpeedCeiling(boat.Assembly.Root)
end

-- THE one release path -- see this file's header on why all six ways off a boat end here. Safe to call
-- on a player who is not mounted (every caller treats it as "make sure this player is not on a boat")
-- and safe to call on a half-destroyed character.
function BoatSystem.Dismount(player: Player): ()
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

	local boat = mount.Boat
	boat.Occupants = math.max(0, boat.Occupants - 1)

	-- THE LAST PERSON OFF FURLS HER, ON THIS FRAME. Not at the end of the drift window, and not via the
	-- mode machine -- immediately, here, because "I am getting off" and "the ship should stop" are the
	-- same intention and any delay between them reads as the ship ignoring you. Formally anchoring is
	-- the separate, later beat (BoatHullMode's own Anchored transition); see BoatConstants.Adrift for
	-- why those two were wrong as one.
	--
	-- The latch is cleared as well as the rung, so a skipper who comes back finds a panel that agrees
	-- with the ship: leaving Adrift armed on a hull that has already taken her sails in would show
	-- ADRIFT over a gauge reading FURLED, which is two panels disagreeing about one fact.
	if boat.Occupants <= 0 then
		boat.AdriftArmed = false
		boat.SailIndex = BoatSailLadder.NeutralIndex()
		boat.Helm = { Steer = 0 }
	end

	if boat.Pilot == player then
		boat.Pilot = nil
		-- Centred on release rather than left latched: a helmsman who disconnects mid-turn must not
		-- leave their last rudder driving the hull for the rest of the round.
		boat.Helm = { Steer = 0 }
		-- THE SAILS ARE THE ONE THING THAT MAY SURVIVE THE PILOT, and only if they armed Adrift before
		-- stepping away AND somebody is still aboard to be carried -- that IS the feature
		-- (BoatConstants.Adrift). Note the Occupants block above has already cleared the latch for an
		-- empty ship, so `AdriftArmed` here can only still be true when there are crew left.
		if not boat.AdriftArmed then
			boat.SailIndex = BoatSailLadder.NeutralIndex()
		end
	end

	-- The whole physical release -- weld, clearance lift, separation velocity, ownership, movement lock
	-- -- in the one strict order Server/Vessel/VesselMount.Release owns.
	mounter.Release(mount.Binding, boat.Assembly.Root)

	-- Armed even when the body above was already gone: the map is keyed by Player, expiry is by
	-- deadline, and a stale entry for a body that no longer exists costs one skipped iteration.
	boat.Released[player] = os.clock() + BoatConstants.Mount.ReleaseSettleSeconds

	-- The passenger's mass has left the assembly, and the weld change means Roblox has had to re-decide
	-- who owns the hull -- both have to be answered, in that order, on every mount change.
	BoatAssembly.RefreshForceLimits(boat.Assembly)
	BoatAssembly.ClaimOwnership(boat.Assembly)

	broadcastMountChanged(mount.Binding.Character, false, nil, nil)
	-- Forced: the state may not have changed at all, but the AUDIENCE has. Sent AFTER mounts[player] was
	-- cleared, so the player who just left is not among the recipients.
	pushHelmUpdatedIfChanged(boat, true)
	logger:debug("Dismounted", { player = player.Name, model = boat.Model.Name })
end

local function mount(player: Player, boat: BoatRecord, station: StationRecord): ()
	if mounts[player] then
		return
	end
	if station.Occupant then
		return
	end

	-- The whole physical mount -- live-rig lookup, server-side reach re-check, movement lock and weld --
	-- in Server/Vessel/VesselMount.Attach. nil means it did not happen (no live rig, or a player who
	-- walked out of reach during the round trip); both are ordinary, neither is an error, and nothing
	-- below this line has run yet, so there is nothing to unwind.
	local binding = mounter.Attach(player, station.Part, station.StandOffset)
	if not binding then
		return
	end

	station.Occupant = player
	setPromptEnabled(station, false)
	boat.Occupants += 1
	-- Cancelled, not left to expire: a player who steps off and straight back on within the window is
	-- welded rigidly into the hull again, and clamping a member of the hull's own assembly against the
	-- hull's own speed would be the tick loop fighting the drive constraint through their body.
	boat.Released[player] = nil
	if station.Kind == "Helm" then
		boat.Pilot = player
		-- Centred on mount, not carried: whatever the previous helmsman was holding when they let go is
		-- not a command the new one gave. The SAILS are deliberately left alone -- taking the helm of a
		-- ship already making way should not take her canvas off under the new skipper's feet, and the
		-- rung is right there on their panel the moment they arrive.
		boat.Helm = { Steer = 0 }
	end

	mounts[player] = {
		Player = player,
		Boat = boat,
		Station = station,
		Binding = binding,
	}

	BoatAssembly.RefreshForceLimits(boat.Assembly)
	BoatAssembly.ClaimOwnership(boat.Assembly)

	broadcastMountChanged(binding.Character, true, station.Kind, station.Part)
	-- Forced -- this client has never seen a snapshot for this hull, and waiting for the edge detector
	-- would leave its panel blank until somebody else moved the sails.
	pushHelmUpdatedIfChanged(boat, true)
	logger:info("Mounted", { player = player.Name, model = boat.Model.Name, kind = station.Kind })
end

local function onHullTouched(boat: BoatRecord, otherPart: BasePart): ()
	local character = otherPart:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	boat.Contacts[player] = (boat.Contacts[player] or 0) + 1
end

local function onHullTouchEnded(boat: BoatRecord, otherPart: BasePart): ()
	local character = otherPart:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	local count = boat.Contacts[player]
	if not count then
		return
	end
	if count <= 1 then
		boat.Contacts[player] = nil
	else
		boat.Contacts[player] = count - 1
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
-- registered -- see registerBoat's own REGISTERING A TEMPLATE header for the state this exists to
-- survive. Namespaced names, all five of them ours (VesselAssembly.Build and
-- VesselMount.BuildStationPrompt, under this layer's "Boat" scope, are the only things in the game that
-- create them), so this can never eat a builder's own object.
local OWNED_INSTANCE_NAMES: { [string]: boolean } = {
	BoatHullWeld = true,
	BoatDriveAnchor = true,
	BoatDrivePosition = true,
	BoatDriveOrientation = true,
	[BoatConstants.Prompt.StationPromptName] = true,
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

-- REGISTERING A TEMPLATE IS THE BUG THIS FUNCTION'S FIRST TWO GUARDS EXIST FOR, and it is not
-- hypothetical here -- it is a bug this codebase has already shipped once, on blimps, and the reasoning
-- is written out in full in Server/Systems/BlimpSystem.registerBlimp's own header. In short:
-- CollectionService:GetTagged searches the WHOLE DataModel, not the Workspace, so a Boat template parked
-- in ServerStorage for Server/Systems/VehicleManager.lua to clone comes back from Init's boot sweep
-- looking like a hull. Registering it welds it, unanchors it and parents drive constraints and prompts
-- into it -- and :Clone() copies every one of those, so each spawned boat arrives already carrying a
-- constraint aimed at where the template was standing and a second, unconnected prompt on her wheel.
-- The symptoms read as two unrelated bugs: a boat that will not move, and a helm that works half the
-- time.
--
-- So: register nothing that is not actually in the world, and strip anything a model inherited from a
-- registration that happened before it got there. The second guard is not redundant with the first --
-- it is what makes a place file SAVED while a template was polluted recover on its own.
local function registerBoat(model: Model): ()
	if boats[model] then
		return
	end

	if not model:IsDescendantOf(Workspace) then
		-- Not an error and not a build mistake -- this is the normal state of a VehicleManager template.
		-- Watched rather than dropped, so a builder who parks a tagged hull outside Workspace and drags
		-- it in at runtime still gets a boat.
		if not pendingWorldEntry[model] then
			logger:info("Tagged model is not in the world -- not registering it until it is", {
				model = model:GetFullName(),
			})
			pendingWorldEntry[model] = model.AncestryChanged:Connect(function()
				if model:IsDescendantOf(Workspace) then
					cancelPendingWorldEntry(model)
					registerBoat(model)
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

	-- Both warnings below register the boat anyway. A hull with no stations yet is a normal state to be
	-- in while building one, and it still needs its parts welded into an assembly for the builder to see
	-- it float -- she simply has nowhere to stand, which the log says out loud rather than leaving as a
	-- mystery the first time somebody walks up to her and nothing happens.
	local stations, helm = BoatTagging.ResolveStations(model)
	if #stations == 0 then
		logger:warn("Tagged model has no helm or handhold stations", { model = model:GetFullName() })
	elseif not helm then
		logger:warn("Tagged model has handholds but no helm -- nobody can steer it", {
			model = model:GetFullName(),
		})
	end

	local assembly = BoatAssembly.Build(model)
	if not assembly then
		return
	end

	-- The single most likely authoring mistake in this layer, and the only one that makes every boat in
	-- the place look broken rather than plain -- warned about once, here, because a boat being registered
	-- into a waterless world is a real mistake happening right now.
	BoatWater.WarnIfWorldHasNoWater(model)

	local trove = Trove.New()
	trove:Add(function()
		BoatAssembly.Destroy(assembly)
	end)

	-- The helm's stand offset is resolved before the tuning because the BOW is derived from it -- see
	-- VesselTagging.ResolveForwardYaw. Getting the helmsman standing right is the same act as getting the
	-- boat sailing the right way, deliberately.
	local helmStandOffset = if helm then BoatTagging.ResolveStandOffset(helm, model) else nil
	local tuning = BoatTagging.ResolveTuning(model)
	tuning.ForwardYawRadians = BoatTagging.ResolveForwardYaw(model, assembly.Root, helm, helmStandOffset)

	local wake = BoatTagging.ResolveWakeEmitters(model)
	local wakeWasEnabled: { [ParticleEmitter]: boolean } = {}
	for _, emitter in wake do
		wakeWasEnabled[emitter] = emitter.Enabled
		-- Lying still is the state every boat starts in, whatever the builder left the emitter checkbox
		-- on in Studio -- otherwise a moored boat sits there throwing spray.
		emitter.Enabled = false
	end
	trove:Add(function()
		for emitter, wasEnabled in wakeWasEnabled do
			if emitter.Parent then
				emitter.Enabled = wasEnabled
			end
		end
	end)

	local record: BoatRecord = {
		Model = model,
		Assembly = assembly,
		Tuning = tuning,
		Drive = BoatDrive.NewState(assembly.Root.CFrame),
		Helm = { Steer = 0 },
		-- Every hull is registered furled, whatever the builder left her doing in Studio -- the same
		-- "lying still is the state every boat starts in" posture the wake reset above takes, applied to
		-- the sails.
		SailIndex = BoatSailLadder.NeutralIndex(),
		AdriftArmed = false,
		Hull = BoatHullMode.NewState(),
		Pilot = nil,
		Stations = {},
		Occupants = 0,
		Wake = wake,
		Making = false,
		LastHelmPush = nil,
		Contacts = {},
		Released = {},
		Trove = trove,
	}

	-- Wired on every hull part, not just Root -- a big hull can be touched anywhere along her length,
	-- and Touched is a per-BasePart signal even though every part here moves rigidly together.
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
			else BoatTagging.ResolveStandOffset(station.Part, model)
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

	boats[model] = record
	logger:info("Boat registered", { model = model:GetFullName(), stations = #stations })
end

local function unregisterBoat(model: Model): ()
	-- Dropped first and unconditionally: an untagged model that never made it into the world has no
	-- record here at all, only the AncestryChanged watch registerBoat left on it, and returning early
	-- below would leak exactly that.
	cancelPendingWorldEntry(model)

	local record = boats[model]
	if not record then
		return
	end
	boats[model] = nil

	-- Everyone aboard comes off BEFORE the assembly is dismantled: a mount torn down after its weld's
	-- Part0 has already been restored leaves a body whose release path cannot find what it was holding.
	for player, mountRecord in mounts do
		if mountRecord.Boat == record then
			BoatSystem.Dismount(player)
		end
	end

	record.Trove:Clean()
	logger:info("Boat unregistered", { model = model.Name })
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
		local payload: VesselTypes.MountChangedPayload = {
			Character = mountRecord.Binding.Character,
			Active = true,
			Kind = mountRecord.Station.Kind,
			Station = mountRecord.Station.Part,
		}
		remote:FireClient(player, payload)
	end
end

-- Resolves the boat `player` is currently STEERING, or nil. Shared by all three helm remotes below.
--
-- A passenger reaching any of them is dropped here, silently and by design: it is a legal thing for a
-- client to have in flight (they were the helmsman a frame ago) rather than evidence of tampering.
local function pilotedBoat(player: Player): BoatRecord?
	local mountRecord = mounts[player]
	if not mountRecord then
		return nil
	end
	local boat = mountRecord.Boat
	if boat.Pilot ~= player then
		return nil
	end
	return boat
end

local function handleSetHelmInput(player: Player, raw: unknown): ()
	if intentRateLimiter:IsLimited(player) then
		return
	end
	local boat = pilotedBoat(player)
	if not boat then
		return
	end
	local helm = BoatDrive.SanitizeHelmInput(raw)
	if not helm then
		return
	end
	boat.Helm = helm
end

-- Moves the sails. A signed rung delta, or 0 to furl outright -- see VesselSpeedLadder.Shift, which owns
-- both meanings.
local function handleShiftSailState(player: Player, raw: unknown): ()
	if sailShiftRateLimiter:IsLimited(player) then
		return
	end
	local boat = pilotedBoat(player)
	if not boat then
		return
	end
	local delta = BoatSailLadder.SanitizeDelta(raw)
	if not delta then
		return
	end
	boat.SailIndex = BoatSailLadder.Shift(boat.SailIndex, delta)
	pushHelmUpdatedIfChanged(boat, false)
end

local function handleToggleAdrift(player: Player): ()
	if adriftRateLimiter:IsLimited(player) then
		return
	end
	local boat = pilotedBoat(player)
	if not boat then
		return
	end
	boat.AdriftArmed = not boat.AdriftArmed
	pushHelmUpdatedIfChanged(boat, false)
end

local function handleRequestDismount(player: Player): ()
	if dismountRateLimiter:IsLimited(player) then
		return
	end
	BoatSystem.Dismount(player)
end

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
			BoatSystem.Dismount(player)
		end
	end
end

-- ONE scratch table, refilled per hull per tick, rather than a fresh literal each time -- the same trick
-- BlimpSystem's own flightContextScratch uses, and with the same single rule: nothing may hold onto the
-- table it is handed. BoatHullMode.Step is pure and returns a new State, and ResolveIntent only reads.
local hullContextScratch: BoatHullMode.Context = {
	HasPilot = false,
	OccupantCount = 0,
	AdriftArmed = false,
	WaterSupported = false,
}

-- Piggybacks GameplayEvents.OnHeartbeatTick rather than opening a second RunService.Heartbeat connection
-- -- that signal's own header names this as the sanctioned seam for exactly this kind of per-frame work.
local function onHeartbeatTick(deltaTime: number): ()
	if next(boats) == nil then
		return
	end

	-- Read once for the whole sweep rather than per boat: os.clock() is not free at this cadence, and
	-- the wind is one value for the whole world (see BoatConstants.Wind) so sampling it per hull would
	-- be the same answer computed six times.
	local now = os.clock()
	local wind = BoatWind.Sample(Workspace:GetServerTimeNow())

	for _, boat in boats do
		local root = boat.Assembly.Root

		-- The water is probed at the TARGET's position rather than the hull's actual one. Deliberate: the
		-- integrator advances its own Target and the hull chases it, so sampling where the hull IS would
		-- feed the drive a surface height one lag-length behind the place it is about to put her -- which
		-- on a swell is a hull that bobs a beat late, and at a shoreline is one that beaches a moment
		-- after she visibly ran aground.
		local water = BoatWater.SampleAt(boat.Drive.Target.Position)

		local context = hullContextScratch
		context.HasPilot = boat.Pilot ~= nil
		context.OccupantCount = boat.Occupants
		context.AdriftArmed = boat.AdriftArmed
		context.WaterSupported = water.Supported

		local previousMode = boat.Hull.Mode
		boat.Hull = BoatHullMode.Step(boat.Hull, context, deltaTime)

		-- THE LATCH IS DROPPED WHEN THE MACHINE GIVES UP ON HER, on the edge and not every tick, so a
		-- returning skipper's panel agrees with what the ship is actually doing. The rung goes with it:
		-- an anchored hull with FULL SAIL still showing on the gauge is the panel lying.
		if boat.Hull.Mode == "Anchored" and previousMode ~= "Anchored" then
			boat.AdriftArmed = false
			boat.SailIndex = BoatSailLadder.NeutralIndex()
		end

		local sailFraction = BoatSailLadder.ThrottleAt(boat.SailIndex)
		local intent = BoatHullMode.ResolveIntent(boat.Hull.Mode, context, sailFraction, boat.Helm)

		local previousSpeed = boat.Drive.Speed
		boat.Drive = BoatDrive.Step(
			boat.Drive,
			intent,
			boat.Tuning,
			wind,
			water,
			deltaTime,
			BoatHullMode.DecelerationMultiple(boat.Hull.Mode)
		)

		-- Fed back into the state, not just clipped on the way to the constraint -- see
		-- BoatDrive.ClampLead and BlimpDrive's own header: clipping only the output hides one frame of
		-- the debt and keeps banking the rest.
		local clamped = BoatDrive.ClampLead(boat.Drive.Target, root.Position, BoatConstants.Drive.MaxLeadStuds)
		if clamped ~= boat.Drive.Target then
			boat.Drive.Target = clamped
		end

		local surgeAcceleration = if deltaTime > 0 then (boat.Drive.Speed - previousSpeed) / deltaTime else 0
		-- Slopes at where the integration actually LANDED, not where it started -- see
		-- BoatWater.SlopesAt's own comment on why the height and the slope are two calls.
		local slopeX, slopeZ = BoatWater.SlopesAt(boat.Drive.Target.Position)

		boat.Assembly.AlignPosition.Position = boat.Drive.Target.Position
		boat.Assembly.AlignOrientation.CFrame =
			BoatDrive.PresentationCFrame(boat.Drive, boat.Tuning, intent.Sail, wind, surgeAcceleration, slopeX, slopeZ)

		setMakingWay(boat, math.abs(boat.Drive.Speed) >= boat.Tuning.HullSpeed * BoatConstants.Wake.MinSpeedFraction)

		-- Player-contact velocity safety net -- see Shared/Vessel/VesselSafety.lua's header for why this
		-- is necessary at all and independent of everything above it in this loop: the hull's own lead
		-- clamp and MaxDriveVelocity bound the HULL's speed, but a character merely TOUCHING her is a
		-- separate physics body that neither constraint reaches. Walked every tick rather than only from
		-- Touched -- the injection this defends against accrues gradually while contact is sustained.
		for player, count in boat.Contacts do
			if count <= 0 then
				continue
			end
			-- A mounted rider is welded rigidly to the hull and has nothing to drive them with -- skipped
			-- explicitly rather than relied on implicitly, since a stray Touched can still fire for a
			-- welded body.
			if mounts[player] then
				continue
			end
			local character = player.Character
			local bodyRoot = if character then CharacterUtil.RootOf(character) else nil
			if not bodyRoot then
				continue
			end
			local velocity = bodyRoot.AssemblyLinearVelocity
			local trimmed = VesselSafety.ClampSpeed(velocity, BoatConstants.Safety.MaxContactSpeed)
			if trimmed ~= velocity then
				bodyRoot.AssemblyLinearVelocity = trimmed
			end
		end

		-- Release settle window -- a SECOND, tighter clamp on a much smaller set of players, and not a
		-- duplicate of the contact loop above it. That one is the anti-exploit backstop: a wide ceiling
		-- on anyone merely leaning on the hull. This one is the separation impulse: a tighter,
		-- hull-relative ceiling on the handful of players who stopped being PART of the hull in the last
		-- fraction of a second, and it exists because the contact loop provably cannot cover them.
		for player, deadline in boat.Released do
			if now >= deadline or mounts[player] then
				boat.Released[player] = nil
				continue
			end
			local character = player.Character
			local bodyRoot = if character then CharacterUtil.RootOf(character) else nil
			if not bodyRoot then
				continue
			end
			-- Linear only, unlike VesselMount.ClampSeparatedBody's one-shot at the moment of release. The
			-- spin a body inherits FROM the hull is a single event and is already gone by here; re-zeroing
			-- every tick for three quarters of a second would instead be overwriting the player's own
			-- turning, which by this point is theirs and not the ship's.
			local velocity = bodyRoot.AssemblyLinearVelocity
			local trimmed = VesselSafety.ClampSpeed(velocity, releaseSpeedCeiling(boat))
			if trimmed ~= velocity then
				bodyRoot.AssemblyLinearVelocity = trimmed
			end
		end

		-- The helm snapshot, on its own edge -- a mode change, a rung change or an Adrift toggle. Cheap
		-- enough to ask every tick because the detector is three exact comparisons and the common answer
		-- is "nothing moved". Nothing continuous rides on it.
		pushHelmUpdatedIfChanged(boat, false)
	end

	if now - lastSweepAt >= BoatConstants.Mount.StaleSweepSeconds then
		lastSweepAt = now
		sweepStaleMounts()
	end
end

function BoatSystem.Init(): ()
	BoatWater.Start()

	mountChangedRemote = NetworkBridge.CreateRemoteEvent(BoatConstants.Network.RemoteNames.MountChanged)

	local setHelmInputRemote = NetworkBridge.CreateRemoteEvent(BoatConstants.Network.RemoteNames.SetHelmInput)
	setHelmInputRemote.OnServerEvent:Connect(handleSetHelmInput)

	local shiftSailRemote = NetworkBridge.CreateRemoteEvent(BoatConstants.Network.RemoteNames.ShiftSailState)
	shiftSailRemote.OnServerEvent:Connect(handleShiftSailState)

	local toggleAdriftRemote = NetworkBridge.CreateRemoteEvent(BoatConstants.Network.RemoteNames.ToggleAdrift)
	toggleAdriftRemote.OnServerEvent:Connect(handleToggleAdrift)

	local requestDismountRemote = NetworkBridge.CreateRemoteEvent(BoatConstants.Network.RemoteNames.RequestDismount)
	requestDismountRemote.OnServerEvent:Connect(handleRequestDismount)

	-- Server -> everyone aboard one hull, never listened to server-side -- see
	-- BoatConstants.Network.RemoteNames.HelmUpdated's own comment.
	helmUpdatedRemote = NetworkBridge.CreateRemoteEvent(BoatConstants.Network.RemoteNames.HelmUpdated)

	-- Present-at-boot models and future ones through the same function, which is the whole reason
	-- GetTagged is read before the Added signal is connected rather than after: a model tagged in the
	-- window between the two would otherwise be registered twice, and registerBoat's own guard is what
	-- makes the overlap harmless in the other direction.
	for _, tagged in CollectionService:GetTagged(BoatConstants.Tags.Model) do
		if tagged:IsA("Model") then
			registerBoat(tagged :: Model)
		end
	end
	CollectionService:GetInstanceAddedSignal(BoatConstants.Tags.Model):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			registerBoat(instance :: Model)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(BoatConstants.Tags.Model):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			unregisterBoat(instance :: Model)
		end
	end)

	GameplayEvents.OnHeartbeatTick(onHeartbeatTick)
	GameplayEvents.OnPlayerKilled(function(victim: Player, _killer: Player?)
		BoatSystem.Dismount(victim)
	end)

	PlayerLifecycle.BindAllPlayers({
		Scope = "BoatSystem",
		-- Catch-up. MountChanged is an EDGE, so a player who joins after somebody took the helm would
		-- otherwise never hear about it and would see that helmsman standing at the wheel with their arms
		-- by their sides for the rest of the voyage -- the pose is per-client
		-- (Shared/Vessel/VesselArmPose.lua's header), so a client that missed the edge has no other way
		-- to learn the state.
		OnPlayer = function(player: Player, _session: Trove.TroveInstance)
			sendExistingMounts(player)
		end,
		-- A new life is never mounted, and the OLD life's mount has to be released before the body it was
		-- welded to is collected -- both are this one call, on both edges.
		OnCharacterRemoving = function(player: Player, _character: Model)
			BoatSystem.Dismount(player)
		end,
		OnPlayerRemoving = function(player: Player)
			BoatSystem.Dismount(player)
			intentRateLimiter:Clear(player)
			dismountRateLimiter:Clear(player)
			sailShiftRateLimiter:Clear(player)
			adriftRateLimiter:Clear(player)
		end,
	})

	logger:info("BoatSystem.Init() complete")
end

-- Read by nothing in the shipping game today; exists because the arm pose is client-side and a server
-- spec has no other way to assert that a mount actually produced a poseable pairing. Kept deliberately
-- narrow (a station part, not the whole record) so a future consumer cannot reach the mount's internals
-- through it.
function BoatSystem.GetMountedStation(player: Player): (BasePart?, VesselTypes.StationKind?)
	local mountRecord = mounts[player]
	if not mountRecord then
		return nil, nil
	end
	return mountRecord.Station.Part, mountRecord.Station.Kind
end

return BoatSystem :: Types.SystemModule
