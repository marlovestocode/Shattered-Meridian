--!strict
--[[
	SwingRootClient.lua

	Owns: the client half of "a move that Locks movement actually holds its attacker" -- standing the local
	Humanoid's jump down for as long as Constants.Attributes.SwingRooted is set on it.

	WHY THE CLIENT HAS A HALF AT ALL. Server/Systems/RunSystem.lua pins WalkSpeed to 0 off SwingRooted, which
	stops the body walking -- but the client is the one simulating its own Humanoid, and a Humanoid at
	WalkSpeed 0 still jumps. A lock that lets the attacker hop out of it is not a lock. Client/Combat/
	GrabInputClient.lua does the identical stand-down for a grab throw's GrabThrowing; this is that, for a
	swing, and the two do not undo each other (see restoreJump).

	JUMP ONLY. Not AutoRotate: a locked swing still turns to its target (SwingTracking) and a shift-locked
	camera still turns the body, and freezing either would read as the game ignoring the player's aim.

	Does not own: setting the Attribute (Server/Combat/HitboxEngine/HitboxEngine.lua's movement lock), the
	walk-speed half (RunSystem), or parkour's hand-over (ParkourController reads RootControlLocked).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)

local logger = Logger.scope("SwingRootClient")

local SwingRootClient = {}

local started = false

-- Hands jumping back -- unless a grab throw is still standing it down (GrabInputClient's own
-- GrabThrowing), in which case that module restores it when the throw ends.
local function restoreJump(humanoid: Humanoid): ()
	if humanoid:GetAttribute(Constants.Attributes.GrabThrowing) == true then
		return
	end
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
end

local function apply(humanoid: Humanoid, rooted: boolean): ()
	if rooted then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	else
		restoreJump(humanoid)
	end
end

function SwingRootClient.Start(): ()
	if started then
		return
	end
	started = true

	PlayerLifecycle.BindLocalCharacter({
		Scope = "SwingRootClient",
		OnCharacter = function(_character: Model, humanoid: Humanoid, life)
			local attribute = Constants.Attributes.SwingRooted
			life:Connect(humanoid:GetAttributeChangedSignal(attribute), function()
				apply(humanoid, humanoid:GetAttribute(attribute) == true)
			end)
			-- Bound mid-lock (a respawn race): there is no edge left to catch.
			if humanoid:GetAttribute(attribute) == true then
				apply(humanoid, true)
			end
		end,
	})

	logger:info("SwingRootClient started")
end

return SwingRootClient
