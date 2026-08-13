--!strict
-- Covers Client/Parkour/States/StateSupport.lua's pure, Vector3-in/boolean-out helpers -- the parts
-- of a module that otherwise only exists to be handed a live ParkourContext.
--
-- StateSupport.IsMovingToward is the one function here worth its own file: it is the shared gate
-- Mantling.CanEnter and Vaulting.CanEnter both call to refuse a traversal whose LIVE travel direction
-- has diverged from the obstacle's face since the obstacle was probed -- the fix for "can mantle/vault
-- backward." A bug in the angle convention or the sign of the normal negation would silently let every
-- caller through (or refuse every caller), so it is asserted directly against the same geometry
-- ObstacleProbe.Normal actually reports: an OUTWARD face normal, pointing back at whoever is
-- approaching it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local StateSupport = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States.StateSupport)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

return function()
	describe("StateSupport.IsMovingToward", function()
		it("allows a dead-on approach", function()
			-- Wall facing the character (-Z travel into a wall whose outward normal is +Z).
			expect(StateSupport.IsMovingToward(Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), 65)).to.equal(true)
		end)

		it("allows a diagonal approach inside the threshold", function()
			local travel = Vector3.new(-1, 0, -1).Unit
			expect(StateSupport.IsMovingToward(travel, Vector3.new(0, 0, 1), 65)).to.equal(true)
		end)

		it("refuses a dead-sideways approach", function()
			-- Running along the face (perpendicular to the inward direction) is 90 degrees off -- past
			-- any threshold that still means "walking into it."
			expect(StateSupport.IsMovingToward(Vector3.new(1, 0, 0), Vector3.new(0, 0, 1), 65)).to.equal(false)
		end)

		it("refuses moving directly AWAY from the face -- the backward-vault case", function()
			-- Travel is +Z (away from the wall) while the wall's outward normal is also +Z, i.e. the
			-- character is retreating from the exact face it supposedly found. This is the geometry a
			-- reversed input produces and is exactly what this gate exists to catch.
			expect(StateSupport.IsMovingToward(Vector3.new(0, 0, 1), Vector3.new(0, 0, 1), 65)).to.equal(false)
		end)

		it("treats the threshold angle itself as passing", function()
			-- 65 degrees off dead-on, still inside a 65-degree max.
			local radians = math.rad(65)
			local travel = Vector3.new(math.sin(radians), 0, -math.cos(radians))
			expect(StateSupport.IsMovingToward(travel, Vector3.new(0, 0, 1), 65)).to.equal(true)
		end)

		it("refuses a degenerate (zero) outward normal rather than passing by default", function()
			expect(StateSupport.IsMovingToward(Vector3.new(0, 0, -1), Vector3.zero, 65)).to.equal(false)
		end)

		it("ignores the vertical component of both vectors -- this is a planar question", function()
			-- A steep obstacle face and a travel direction with vertical drift should classify identically
			-- to their flattened counterparts; an accidental Y contribution would make the same horizontal
			-- approach pass or fail depending on how much the character is falling.
			local travel = Vector3.new(0, -5, -1)
			expect(StateSupport.IsMovingToward(travel, Vector3.new(0, 0.6, 1), 65)).to.equal(true)
		end)
	end)

	describe("ParkourConstants.Obstacle.MaxApproachAngleDegrees", function()
		it("sits strictly between 'requires a square hit' and 'sideways still counts'", function()
			local threshold = ParkourConstants.Obstacle.MaxApproachAngleDegrees
			expect(threshold > 0).to.equal(true)
			expect(threshold < 90).to.equal(true)
		end)
	end)
end
