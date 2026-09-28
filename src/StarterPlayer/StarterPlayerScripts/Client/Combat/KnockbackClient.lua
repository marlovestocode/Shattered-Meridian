--!strict
--[[
	KnockbackClient.lua

	Owns: applying a knockback launch to the LOCAL player's own body -- the launch the server decided and
	delivered on the Defender copy of Combat_Feedback (DamageTypes.CombatFeedback.Knockback).

	WHY HERE. The local player's character is simulated by this client; a server velocity write on it is
	overwritten by this machine's next replicated frame (Server/Combat/Damage/DamageSystem.lua's header).
	So the server decides the launch -- direction, magnitude, clamps -- and this module decides nothing
	about it except where in its own frame to write it. It cannot ask for a different knock, and a client
	that declines to apply one is what Server/Combat/Damage/KnockbackAudit.lua watches for.

	THE SHAPE OF A LAUNCH, and why it is not one write:
	  * it STARTS AFTER THE HIT-STOP. CombatFeedbackClient freezes the victim's movement for a beat on the
	    same event (HitStop.FreezeVictimMovement writes zero velocity every frame of it), so a launch
	    written on arrival would be erased by the freeze. Launch takes the freeze length as its delay --
	    freeze, then fly, which is also how a heavy hit should read.
	  * the VERTICAL part is written once, on the first frame, and left to gravity -- a real arc.
	  * the HORIZONTAL part is held for DamageConstants.Knockback.HoldSeconds, decaying linearly to zero,
	    because a grounded Humanoid's own walk controller drags horizontal velocity back toward the
	    player's input within a couple of frames; a single write reads as a flinch. After the first
	    frame, Y is carried through untouched (the SwingLunge rule: never assign the axis you do not own).
	  * a newer launch REPLACES an older one mid-hold -- the body goes where the latest hit sends it.

	Writes only through ParkourMotor.ApplyExternalImpulse, the single seam for "something outside the
	parkour state machine needs this body to move" -- which already refuses during a kinematic traversal
	and while the server holds root control (a grab, a mount), both correctly "not now" for a knock too,
	and which ENDS a velocity-driven parkour state (a roll, a slide) instead of letting its drive erase
	the launch on the next physics step. See that function's own header.

	Does not own: the launch (DamageSystem), the freeze (Client/FX/HitStop.lua), or deciding which hits
	launch (CombatFeedbackClient hands over whatever the server put on the payload).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local Knockback = require(ReplicatedStorage.Shared.Damage.Knockback)

local ParkourMotor = require(script.Parent.Parent.Parkour.ParkourMotor)

local KnockbackClient = {}

type Active = {
	Launch: Vector3,
	StartsAt: number,
	-- Whether the first (full, vertical-including) write has happened yet.
	Launched: boolean,
}

local active: Active? = nil
local heartbeat: RBXScriptConnection? = nil

-- The horizontal velocity to hold `elapsed` seconds into a launch whose flat part is `horizontal`.
-- Linear decay to zero over `holdSeconds`, zero outside it. Pure, so a spec checks the curve with no
-- rig. Decays rather than cutting off for SwingLunge's reason: a flat hold ends in a one-frame stop.
function KnockbackClient.HorizontalAt(horizontal: Vector3, holdSeconds: number, elapsed: number): Vector3
	if holdSeconds <= 0 or elapsed < 0 or elapsed >= holdSeconds then
		return Vector3.zero
	end
	return horizontal * (1 - elapsed / holdSeconds)
end

-- The full velocity to write on a given frame of the launch: the first frame carries the launch's own
-- vertical part, every later one carries the body's current vertical velocity through untouched.
function KnockbackClient.VelocityAt(
	launch: Vector3,
	holdSeconds: number,
	elapsed: number,
	isFirstFrame: boolean,
	currentVelocity: Vector3
): Vector3
	local flat = Knockback.Horizontal(launch)
	local held = KnockbackClient.HorizontalAt(flat, holdSeconds, elapsed)
	local y = if isFirstFrame then launch.Y else currentVelocity.Y
	return Vector3.new(held.X, y, held.Z)
end

local function stop(): ()
	active = nil
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

local function onHeartbeat(): ()
	local current = active
	if current == nil then
		stop()
		return
	end
	local now = os.clock()
	if now < current.StartsAt then
		return
	end
	local hold = DamageConstants.Knockback.HoldSeconds
	local elapsed = now - current.StartsAt
	local isFirst = not current.Launched
	if not isFirst and elapsed >= hold then
		stop()
		return
	end
	local character = Players.LocalPlayer.Character
	local root = if character then CharacterUtil.RootOf(character) else nil
	if root == nil then
		-- Mid-respawn: no body to launch.
		stop()
		return
	end
	local desired = KnockbackClient.VelocityAt(current.Launch, hold, elapsed, isFirst, root.AssemblyLinearVelocity)
	if ParkourMotor.ApplyExternalImpulse(desired) then
		current.Launched = true
	elseif isFirst then
		-- Refused on the first frame (a vault owns the body, or the server does): this launch is not
		-- going to happen, and holding its horizontal part afterwards would be a knock with no lift.
		stop()
	end
end

-- Launches the local body by `launch`, starting `delaySeconds` from now (the hit-stop freeze length).
function KnockbackClient.Launch(launch: Vector3, delaySeconds: number): ()
	if typeof(launch) ~= "Vector3" or launch ~= launch then
		return
	end
	active = {
		Launch = launch,
		StartsAt = os.clock() + math.max(0, delaySeconds),
		Launched = false,
	}
	if heartbeat == nil then
		heartbeat = RunService.Heartbeat:Connect(onHeartbeat)
	end
end

return KnockbackClient
