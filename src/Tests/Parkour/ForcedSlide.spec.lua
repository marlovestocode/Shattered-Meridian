--!strict
-- Covers the FORCED slide -- a slope too steep to stand on (ParkourConstants.Slope.ForcedSlideAngleDegrees)
-- taking the character into States/Sliding.lua without a press.
--
-- Two bugs, both pinned here:
--   1. Idle, Walking and Sprinting used to return "Sliding" from their own Update -- a route-1 hand-off,
--      which never asks Sliding.CanEnter -- so a forced slide skipped the cooldown, the combat gate and a
--      realm's NoParkour (the server refused the Start, the client fell back to Idle, Idle forced the slide
--      again: a loop). The ground states must now leave it to pre-emption, and CanEnter must gate it.
--   2. A forced slide ended the moment the slope read below the threshold, so a surface sitting AT the
--      threshold cycled the slide once per cooldown. It now ends only past the hysteresis band.
--
-- Contexts are built by hand: CanEnter is side-effect free and Update reads only the context it is handed
-- (StateFacingGates.spec's reasoning). The one module-level value touched is Sliding's own cooldown, which
-- is stamped against a clock far in the past so it has lapsed for every other spec in the run.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)

local SLOPE = ParkourConstants.Slope
local SLIDE = ParkourConstants.Slide

local function findDefinition(id: string)
	for _, definition in States do
		if definition.Id == id then
			return definition
		end
	end
	error(`no state definition registered for {id}`)
end

local Sliding = findDefinition("Sliding")

-- A ground normal tilted `degrees` from vertical, falling away toward +Z.
local function normalAt(degrees: number): Vector3
	local radians = math.rad(degrees)
	return Vector3.new(0, math.cos(radians), math.sin(radians))
end

return function()
	local parts: { BasePart } = {}

	local function context(slopeDegrees: number, overrides: { [string]: any }?): any
		local root = Instance.new("Part")
		table.insert(parts, root)
		local built = {
			RootPart = root,
			-- Far in the past: anything this spec stamps on Sliding's cooldown has long lapsed by the time
			-- another spec asks it on the real clock.
			Now = -1000,
			DeltaTime = 1 / 60,
			StateElapsed = 0,
			Momentum = 12,
			PlanarSpeed = 12,
			MoveIntent = Vector3.new(0, 0, 1),
			MoveDirection = Vector3.new(0, 0, 1),
			SprintHeld = false,
			SprintStage = 0,
			InCombat = false,
			DomainSealed = false,
			CeilingClear = true,
			Motor = { Mode = "Humanoid", DesiredSpeed = 0, Velocity = Vector3.zero, HipHeightDelta = 0 },
			Ground = {
				Grounded = true,
				NearGround = true,
				Distance = 0,
				SlopeAngle = slopeDegrees,
				Normal = normalAt(slopeDegrees),
				FrictionScale = 1,
			},
			Obstacle = { Found = false, Distance = math.huge },
		}
		if overrides then
			for key, value in overrides do
				(built :: any)[key] = value
			end
		end
		return built
	end

	-- Sliding's cooldown is module state, and another spec may have stamped it on the real clock -- which is
	-- far ahead of this spec's. Exit always assigns it, so exiting at an even earlier time clears it to
	-- "lapsed" for this spec and for every real-clock spec after it.
	beforeEach(function()
		local reset = context(0)
		reset.Now = -2000
		Sliding.Exit(reset, "Walking")
	end)

	afterEach(function()
		for _, part in parts do
			part:Destroy()
		end
		table.clear(parts)
	end)

	describe("the ground states", function()
		it("never hand off to Sliding themselves on a too-steep slope", function()
			local steep = SLOPE.ForcedSlideAngleDegrees + 5
			for _, id in { "Idle", "Walking", "Sprinting" } do
				local definition = findDefinition(id)
				local ctx = context(steep, {
					MoveIntent = if id == "Idle" then Vector3.zero else Vector3.new(0, 0, 1),
					PlanarSpeed = if id == "Idle" then 0 else 12,
					SprintHeld = id == "Sprinting",
				})
				expect(definition.Update(ctx)).never.to.equal("Sliding")
			end
		end)
	end)

	describe("Sliding.CanEnter on a too-steep slope", function()
		local steep = SLOPE.ForcedSlideAngleDegrees + 5

		it("accepts without a press, so pre-emption still takes the character", function()
			local accepted = Sliding.CanEnter(context(steep))
			expect(accepted).to.equal(true)
		end)

		it("refuses while the combat gate closes the slide", function()
			local accepted, reason = Sliding.CanEnter(context(steep, { InCombat = true }))
			expect(accepted).to.equal(false)
			expect(reason).to.equal("InCombat")
		end)

		it("refuses inside a realm that seals parkour", function()
			local accepted = Sliding.CanEnter(context(steep, { DomainSealed = true }))
			expect(accepted).to.equal(false)
		end)

		it("refuses inside the slide cooldown, and accepts once it lapses", function()
			local ctx = context(steep)
			Sliding.Exit(ctx, "Walking")
			ctx.Now += SLIDE.CooldownSeconds * 0.5
			local accepted, reason = Sliding.CanEnter(ctx)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("SlideCooldown")
			ctx.Now += SLIDE.CooldownSeconds
			expect((Sliding.CanEnter(ctx))).to.equal(true)
		end)
	end)

	describe("a forced slide's exit", function()
		local function updateOn(slopeDegrees: number): string?
			local ctx = context(SLOPE.ForcedSlideAngleDegrees + 5)
			Sliding.Enter(ctx, "Walking")
			ctx.Ground.SlopeAngle = slopeDegrees
			ctx.Ground.Normal = normalAt(slopeDegrees)
			ctx.StateElapsed = SLIDE.MinDurationSeconds + 0.1
			local result = Sliding.Update(ctx)
			Sliding.Exit(ctx, "Walking")
			return result
		end

		it("holds the slide just under the threshold, inside the hysteresis band", function()
			expect(updateOn(SLOPE.ForcedSlideAngleDegrees - SLOPE.ForcedSlideExitHysteresisDegrees * 0.5)).to.equal(nil)
		end)

		it("ends the slide once the ground is clearly shallower", function()
			local result = updateOn(SLOPE.ForcedSlideAngleDegrees - SLOPE.ForcedSlideExitHysteresisDegrees - 2)
			expect(result).to.be.ok()
			expect(result).never.to.equal("Sliding")
		end)
	end)
end
