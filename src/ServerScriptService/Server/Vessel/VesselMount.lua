--!strict
--[[
	VesselMount.lua

	Owns: the physical act of putting a player ON a vehicle station and taking them off again -- the
	station's ProximityPrompt, the server-side reach re-check, the movement lock, the weld, and the whole
	ordered release sequence that stops a body leaving a moving hull at the hull's rotational speed.
	Nothing here knows what KIND of vehicle it is attached to, holds any registry, or decides who is
	allowed to mount: it is handed a station and a player and does exactly the mechanical part.

	LIFTED OUT OF Server/Systems/BlimpSystem.lua when the Boat layer arrived. That extraction is narrower
	than it might have been, deliberately: `mount` and `Dismount` over there also do a great deal that is
	specific to an airship (ringing the telegraph down, clearing an autopilot latch, cutting the exhaust,
	pushing a fuel snapshot), and pulling that up here would have required a callback per vehicle-specific
	beat, which is a worse way of writing the same code in a further-away file. What moved is only the
	part that is identical because it is about BODIES AND WELDS rather than about vehicles.

	WHY A MOUNT IS A WELD AND NOT A CONSTRAINT PAIR, unlike GrabSystem's hold. A grab drags a body toward
	a moving fist and wants the softness an AlignPosition gives it. A mount is the opposite claim: this
	body IS part of that hull now, exactly here, and any softness at all reads as the player's feet
	skating on the deck. A Weld with an authored C0 also lands the body on its mark on the first frame
	with no pre-positioning race -- which matters, because CFrame-writing a character from the server
	before its ownership has actually changed hands is the exact failure GrabSystem's own header spends a
	paragraph on. It is the same technique Roblox's own Seat uses, for the same reason.

	THE MOVEMENT LOCK REUSES TWO EXISTING SEAMS AND A THIRD THAT WAS ADDED FOR IT:
	  * AttributeConstants.RootControlLocked -- already read generically by ParkourController's
	    resolveCombatOwned as "something else owns this body". Parks client-side parkour for free.
	  * Humanoid.PlatformStand -- suspends the Humanoid's own ground movement so a welded body behaves as
	    part of the hull instead of trying to walk on it.
	  * AttributeConstants.Mounted -- a separate Attribute rather than a widened meaning for
	    RootControlLocked, for the reason that Attribute's own comment gives: in this codebase
	    RootControlLocked has never carried WalkSpeed-zeroing semantics, a dedicated Attribute always
	    does that job. Read by RunSystem.isMovementLocked's tier list, and nowhere else.

	THE RELEASE ORDER IS THE WHOLE OF Release, AND IT IS NOT NEGOTIABLE. Settle the body, then wake the
	Humanoid, then hand ownership back. A body that was welded into the hull was a member of the HULL'S
	assembly; destroying the weld makes it its own assembly, and Roblox seeds a newly separated assembly
	with the velocity the old one had -- BOTH components. Clearing PlatformStand first re-arms the
	Humanoid's balance controller against a spin it did not put there, and the solver converts that
	disagreement into linear speed: the canonical Roblox fling. Handing ownership back first makes every
	correction below a server write onto a body somebody else already owns, which is a fight rather than
	a fix.

	Does not own: who may mount (each vehicle's System), the registry of mounted players (same), anything
	the vehicle does about a mount beginning or ending (same), the prompt's client-local key
	(each vehicle's controller re-keys it from the player's own Interact bind), or the velocity clamp
	arithmetic itself (Shared/Vessel/VesselSafety.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local VesselSafety = require(ReplicatedStorage.Shared.Vessel.VesselSafety)
local VesselTypes = require(ReplicatedStorage.Shared.Vessel.VesselTypes)
-- The one cross-folder require here: a mount is the same "who drives this body" claim the combat writers hold,
-- and a second copy of the claim logic is how the overlapping-writer bug it fixes would come back.
local RootControl = require(ServerScriptService.Server.Combat.RootControl)

local VesselMount = {}

-- What one vehicle layer binds this to. Prompt is that vehicle's own Constants.Prompt, minus the fields
-- only its own bespoke prompts (a furnace, a capstan) use; Mount is the release half of its
-- Constants.Mount.
export type Config = {
	-- Prefixes the logger scope and names the weld this file creates, so a mounted player's Explorer
	-- entry says which system put them there.
	Scope: string,
	Prompt: {
		StationPromptName: string,
		HelmActionText: string,
		HandholdActionText: string,
		HelmObjectText: string,
		HandholdObjectText: string,
		MaxActivationDistance: number,
		HoldDuration: number,
		RequiresLineOfSight: boolean,
	},
	Mount: {
		ReleaseClearance: number,
		ReleaseSpeedMargin: number,
	},
}

-- What a successful Attach hands back -- everything Release needs and nothing else. The owning System
-- keeps this on its own mount record alongside whatever else it tracks.
export type Binding = {
	Character: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Weld: Weld,
}

export type Mounter = {
	BuildStationPrompt: (station: BasePart, kind: VesselTypes.StationKind) -> ProximityPrompt,
	WithinReach: (root: BasePart, station: BasePart) -> boolean,
	Attach: (player: Player, station: BasePart, standOffset: CFrame) -> Binding?,
	Release: (binding: Binding, hullRoot: BasePart?) -> (),
	ReleaseSpeedCeiling: (hullRoot: BasePart?) -> number,
	ClampSeparatedBody: (root: BasePart, hullRoot: BasePart?) -> (),
}

-- How much slack the server-side reach re-check allows over the prompt's own activation distance. The
-- prompt's distance test runs on the TRIGGERING CLIENT, which makes it a UX affordance rather than a
-- gate; this factor is for the honest case of a player who stepped away during the round trip, not for
-- a generous one.
local REACH_SLACK = 1.5

-- One vehicle layer's bound mounter.
function VesselMount.New(config: Config): Mounter
	local logger = Logger.scope(config.Scope .. "Mount")
	local weldName = config.Scope .. "MountWeld"

	local mounter = {}

	-- The station prompt. A tap, not a hold, on purpose: a hold duration is what you use to stop an
	-- accidental press being costly, and mounting is instantly reversible with the same key.
	function mounter.BuildStationPrompt(station: BasePart, kind: VesselTypes.StationKind): ProximityPrompt
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = config.Prompt.StationPromptName
		prompt.ActionText = if kind == "Helm" then config.Prompt.HelmActionText else config.Prompt.HandholdActionText
		prompt.ObjectText = if kind == "Helm" then config.Prompt.HelmObjectText else config.Prompt.HandholdObjectText
		prompt.MaxActivationDistance = config.Prompt.MaxActivationDistance
		prompt.HoldDuration = config.Prompt.HoldDuration
		prompt.RequiresLineOfSight = config.Prompt.RequiresLineOfSight
		prompt.Parent = station
		return prompt
	end

	-- Re-checked server-side even though the ProximityPrompt already enforces it client-side -- see
	-- REACH_SLACK above on why the prompt's own test is not a gate.
	function mounter.WithinReach(root: BasePart, station: BasePart): boolean
		local reach = config.Prompt.MaxActivationDistance * REACH_SLACK
		return (root.Position - station.Position).Magnitude <= reach
	end

	-- Locks `player`'s body and welds it to `station` at `standOffset`. Returns nil (having changed
	-- nothing) for a player with no live rig or one who has walked out of reach during the round trip --
	-- both are ordinary, neither is an error, and the caller treats nil as "the mount did not happen".
	function mounter.Attach(player: Player, station: BasePart, standOffset: CFrame): Binding?
		local character, humanoid, root = CharacterUtil.LiveRig(player)
		if not character or not humanoid or not root then
			return nil
		end

		if not mounter.WithinReach(root, station) then
			logger:debug("Mount refused: out of reach", { player = player.Name, station = station.Name })
			return nil
		end

		humanoid.PlatformStand = true
		RootControl.Claim(humanoid, RootControl.Owners.Vessel)
		humanoid:SetAttribute(AttributeConstants.Mounted, true)

		-- Anchored is checked rather than assumed: a character anchored by an admin freeze would
		-- otherwise anchor the entire hull it is welded into, and the vehicle would stop moving for
		-- everyone aboard.
		root.Anchored = false

		-- C0 carries the whole placement, so the body lands on its mark on the frame the weld is created
		-- -- no pre-positioning CFrame write, and therefore no race against ownership changing hands. See
		-- this file's header.
		local weld = Instance.new("Weld")
		weld.Name = weldName
		weld.Part0 = station
		weld.Part1 = root
		weld.C0 = standOffset
		weld.Parent = root

		return {
			Character = character,
			Humanoid = humanoid,
			Root = root,
			Weld = weld,
		}
	end

	-- The ceiling a just-released (or just-separated) body's own speed is held to: whatever the HULL is
	-- doing right now, plus the margin a self-propelled player could add to it. Read live rather than
	-- cached because it is the whole point -- see each vehicle's Mount.ReleaseSpeedMargin on why an
	-- absolute number is wrong at one end of the throttle or the other no matter where it is set.
	--
	-- A nil (or destroyed) hull root reads as a stationary one, which is the safe direction: the margin
	-- alone is still a legitimate player speed.
	function mounter.ReleaseSpeedCeiling(hullRoot: BasePart?): number
		local hullSpeed = if hullRoot and hullRoot.Parent then hullRoot.AssemblyLinearVelocity.Magnitude else 0
		return hullSpeed + config.Mount.ReleaseSpeedMargin
	end

	-- Makes a body that has just stopped being part of a hull carry a velocity a PERSON could have,
	-- rather than the one the assembly it was welded into happened to have at the moment it left. Two
	-- separate corrections, and they fix two separate halves of the same report:
	--
	--   * THE SPIN, zeroed outright. A hull under way is rotating -- yawing through a turn, pitching over
	--     a swell -- and a separating assembly keeps the whole of that angular velocity, scaled by
	--     nothing. A several-tonne ship's leisurely half-radian-per-second is a violent spin on a body
	--     the size of a person, and the PlatformStand release then hands that spinning body to a Humanoid
	--     balance controller that immediately fights it. That fight is the "flung across the map" half.
	--     Nobody has ever wanted to inherit a ship's rotation by stepping off it, so there is no feel
	--     argument for keeping any fraction of it.
	--
	--   * THE EXCESS SPEED, clamped -- but only the excess. The linear half is inherited ON PURPOSE and
	--     must stay inherited: a passenger who leaves a cruising hull at the hull's own speed lands back
	--     on its deck and walks, whereas one zeroed (or clamped to some flat pedestrian number) is
	--     instantly a hundred studs/second slower than the deck they are standing over, and the deck
	--     sweeps into them. The clamp therefore trims only what is ABOVE the ship's own speed, which is
	--     where the illegitimate part lives: omega x r, the lever arm from the hull's centre of mass out
	--     to a station the artist may have placed eighty studs down the deck, is unbounded in a radius no
	--     constant in this codebase knows about.
	--
	-- Also called by a System's own tick for the settle window after a release -- see each vehicle's
	-- Mount.ReleaseSettleSeconds -- which is why it is exposed separately from Release below.
	function mounter.ClampSeparatedBody(root: BasePart, hullRoot: BasePart?): ()
		root.AssemblyAngularVelocity = Vector3.zero
		local velocity = root.AssemblyLinearVelocity
		local clamped = VesselSafety.ClampSpeed(velocity, mounter.ReleaseSpeedCeiling(hullRoot))
		if clamped ~= velocity then
			root.AssemblyLinearVelocity = clamped
		end
	end

	-- Undoes Attach. Safe on a half-destroyed character: every step checks its own Instance still has a
	-- Parent, and the order of the three below is the entire fix for "everybody who steps off a moving
	-- vehicle flies away" -- see this file's header.
	function mounter.Release(binding: Binding, hullRoot: BasePart?): ()
		binding.Weld:Destroy()

		local root = binding.Root
		if root.Parent then
			-- Lifted before ownership goes back, while the server can still place the body: a dismount
			-- from inside the station part's own volume otherwise resolves as an intersection and flings
			-- them.
			root.CFrame = root.CFrame + Vector3.new(0, config.Mount.ReleaseClearance, 0)
			mounter.ClampSeparatedBody(root, hullRoot)
			-- pcall-guarded the same way GrabSystem's own release is, since both throw on a part whose
			-- assembly has stopped being groundable mid-teardown. LAST, so the state the client is handed
			-- to start simulating from is the corrected one.
			pcall(function()
				root:SetNetworkOwnershipAuto()
			end)
		end

		local humanoid = binding.Humanoid
		if humanoid.Parent then
			-- AFTER the velocity above -- see this file's header on why re-arming the balance controller
			-- on a body still carrying the hull's angular velocity is the canonical Roblox fling.
			humanoid.PlatformStand = false
			-- nil rather than false, clearing the Attribute entirely -- the convention every sibling read
			-- in RunSystem.isMovementLocked uses (`== true`), which treats absent and false identically.
			humanoid:SetAttribute(AttributeConstants.Mounted, nil)
		end
		RootControl.Release(humanoid, RootControl.Owners.Vessel)
	end

	return mounter
end

return VesselMount
