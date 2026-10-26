--!strict
--[[
	SwingRootClient.lua

	Owns: the client half of "a server hold actually holds this body" -- standing the local Humanoid's
	jump down while AttributeConstants.SwingRooted is set on it (a move that Locks movement), and while a
	realm's Rooted rule governs it (Shared/Domain/DomainRules).

	WHY THE CLIENT HAS A HALF AT ALL. Server/Systems/RunSystem.lua pins WalkSpeed to 0 off both, which
	stops the body walking -- but the client is the one simulating its own Humanoid, and a Humanoid at
	WalkSpeed 0 still jumps. A lock that lets the body hop out of it is not a lock. Client/Combat/
	GrabInputClient.lua does the identical stand-down for a grab throw's GrabThrowing. Each is its own
	Client/Movement/JumpGate claim, so none of them can hand the jump back while another still holds it.
	(Parkour's half of a realm root is ParkourController parking in CombatHeld, through
	Shared/Parkour/ParkourOwnership.HeldElsewhere.)

	JUMP ONLY. Not AutoRotate: a locked swing still turns to its target (SwingTracking) and a shift-locked
	camera still turns the body, and freezing either would read as the game ignoring the player's aim.

	Does not own: setting the Attributes (HitboxEngine's movement lock, DomainSystem's rules), the
	walk-speed half (RunSystem), or parkour's hand-over (ParkourController).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)

local JumpGate = require(script.Parent.Parent.Movement.JumpGate)

local logger = Logger.scope("SwingRootClient")

local SwingRootClient = {}

local started = false

-- Bumped on every re-read of the realm rule, so only the newest scheduled lease check acts.
local realmGeneration = 0

local function applySwing(humanoid: Humanoid): ()
	JumpGate.Set(humanoid, JumpGate.Owners.SwingRoot, humanoid:GetAttribute(AttributeConstants.SwingRooted) == true)
end

-- The realm rule is read through its lease. DomainSystem clears the Attributes when a realm ends or a body
-- leaves it, which re-runs this; if that clear never arrives, the lease check scheduled here still hands the
-- jump back at the moment the realm was always going to end -- the lease's whole point.
local function applyRealm(humanoid: Humanoid): ()
	realmGeneration += 1
	local generation = realmGeneration
	local rooted = DomainRules.Has(humanoid, "Rooted")
	JumpGate.Set(humanoid, JumpGate.Owners.RealmRoot, rooted)
	if not rooted then
		return
	end
	local untilTime = humanoid:GetAttribute(AttributeConstants.DomainUntil)
	if typeof(untilTime) ~= "number" then
		return
	end
	task.delay(math.max(untilTime - DomainRules.ServerNow(), 0) + 0.05, function()
		if generation == realmGeneration and humanoid.Parent ~= nil then
			applyRealm(humanoid)
		end
	end)
end

function SwingRootClient.Start(): ()
	if started then
		return
	end
	started = true

	PlayerLifecycle.BindLocalCharacter({
		Scope = "SwingRootClient",
		OnCharacter = function(_character: Model, humanoid: Humanoid, life)
			life:Connect(humanoid:GetAttributeChangedSignal(AttributeConstants.SwingRooted), function()
				applySwing(humanoid)
			end)
			life:Connect(humanoid:GetAttributeChangedSignal(AttributeConstants.DomainFlags), function()
				applyRealm(humanoid)
			end)
			life:Connect(humanoid:GetAttributeChangedSignal(AttributeConstants.DomainUntil), function()
				applyRealm(humanoid)
			end)
			-- Bound mid-hold (a respawn race): there is no edge left to catch.
			applySwing(humanoid)
			applyRealm(humanoid)
		end,
	})

	logger:info("SwingRootClient started")
end

return SwingRootClient
