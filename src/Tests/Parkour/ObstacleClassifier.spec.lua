--!strict
-- Covers Shared/Parkour/ObstacleClassifier.lua -- the height-band decision that turns a measured
-- obstacle into Step / Hop / Vault / Mantle / None.
--
-- Drives the classifier with its OWN synthetic config rather than ParkourConstants.Obstacle, on
-- purpose: these tests are about the band LOGIC, and pinning them to the shipped numbers would mean
-- every future tuning pass broke a dozen assertions that were never about tuning. The one thing
-- checked against the real constants is that the shipped bands are ordered sensibly at all.
--
-- Every case asserts the REASON as well as the action wherever the reason is the interesting part --
-- that string is what Client/Parkour/ParkourDebug.lua shows a developer, so a refusal that reports
-- the wrong reason is a real defect even when the action is right.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ObstacleClassifier = require(ReplicatedStorage.Shared.Parkour.ObstacleClassifier)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

local CONFIG: ObstacleClassifier.ClassifierConfig = {
	StepMaxHeight = 1,
	HopMaxHeight = 2,
	VaultMaxHeight = 4,
	MantleMaxHeight = 8,
	VaultMaxDepth = 3,
	VaultMinSpeed = 10,
	MantleMaxReach = 3,
}

-- A fully-permissive measurement, overridden per test. Written as a builder rather than a shared
-- table so no test can leak state into the next one through a forgotten field.
local function measure(overrides: { [string]: any }?): ObstacleClassifier.ObstacleMeasurement
	local measurement: ObstacleClassifier.ObstacleMeasurement = {
		Found = true,
		Height = 3,
		Depth = 1,
		Distance = 2,
		Speed = 25,
		Grounded = true,
		HasLandingSpace = true,
		HasStandingSpace = true,
		VaultAllowed = true,
		MantleAllowed = true,
	}
	if overrides then
		for key, value in overrides do
			(measurement :: { [string]: any })[key] = value
		end
	end
	return measurement
end

return function()
	describe("ObstacleClassifier.Classify -- nothing to do", function()
		it("returns None when the probe found nothing", function()
			local result = ObstacleClassifier.Classify(measure({ Found = false }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("NoObstacle")
		end)

		it("returns None while airborne -- an obstacle in the air is a ledge or a wall, not a vault", function()
			local result = ObstacleClassifier.Classify(measure({ Grounded = false }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("Airborne")
		end)

		it("returns None for a zero-height hit", function()
			expect(ObstacleClassifier.Classify(measure({ Height = 0 }), CONFIG).Action).to.equal("None")
		end)
	end)

	describe("ObstacleClassifier.Classify -- Step", function()
		it("reports Step for kerb-height geometry the engine already walks over", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 0.6 }), CONFIG)
			expect(result.Action).to.equal("Step")
			expect(result.Reason).to.equal("BelowStepHeight")
		end)

		it("treats the step threshold itself as a Step", function()
			expect(ObstacleClassifier.Classify(measure({ Height = 1 }), CONFIG).Action).to.equal("Step")
		end)

		it("reports Step even from a standstill -- the engine handles it regardless of speed", function()
			expect(ObstacleClassifier.Classify(measure({ Height = 0.6, Speed = 0 }), CONFIG).Action).to.equal("Step")
		end)

		it("is NOT a traversal -- Step means 'seen and deliberately ignored'", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 0.6 }), CONFIG)
			expect(ObstacleClassifier.IsTraversal(result)).to.equal(false)
		end)
	end)

	describe("ObstacleClassifier.Classify -- Hop and Vault", function()
		it("reports Hop just above step height", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 1.5 }), CONFIG)
			expect(result.Action).to.equal("Hop")
			expect(result.Reason).to.equal("HopClear")
		end)

		it("treats the hop threshold itself as a Hop", function()
			expect(ObstacleClassifier.Classify(measure({ Height = 2 }), CONFIG).Action).to.equal("Hop")
		end)

		it("reports Vault just above hop height", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 2.5 }), CONFIG)
			expect(result.Action).to.equal("Vault")
			expect(result.Reason).to.equal("VaultClear")
		end)

		it("treats the vault threshold itself as a Vault", function()
			expect(ObstacleClassifier.Classify(measure({ Height = 4 }), CONFIG).Action).to.equal("Vault")
		end)

		it("refuses below the minimum speed -- vaulting is a momentum move", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 3, Speed = 5 }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("TooSlowToVault")
		end)

		it("refuses when a designer marked the surface unvaultable", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 3, VaultAllowed = false }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("VaultNotAllowedHere")
		end)

		it("counts both Hop and Vault as traversals", function()
			expect(ObstacleClassifier.IsTraversal(ObstacleClassifier.Classify(measure({ Height = 1.5 }), CONFIG))).to.equal(
				true
			)
			expect(ObstacleClassifier.IsTraversal(ObstacleClassifier.Classify(measure({ Height = 3 }), CONFIG))).to.equal(
				true
			)
		end)
	end)

	describe("ObstacleClassifier.Classify -- Mantle", function()
		it("reports Mantle above vault height", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 6 }), CONFIG)
			expect(result.Action).to.equal("Mantle")
			expect(result.Reason).to.equal("MantleClear")
		end)

		it("routes a vault-height but TOO DEEP obstacle to Mantle rather than refusing", function()
			-- The overlap case this ordering exists for: a chest-high wall with a platform behind it
			-- should be climbed onto, not vaulted over into a wall.
			local result = ObstacleClassifier.Classify(measure({ Height = 3, Depth = 10 }), CONFIG)
			expect(result.Action).to.equal("Mantle")
		end)

		it("routes a vault-height obstacle with nowhere to land to Mantle rather than refusing", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 3, HasLandingSpace = false }), CONFIG)
			expect(result.Action).to.equal("Mantle")
		end)

		it("needs no speed at all -- a standing player can climb", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 6, Speed = 0 }), CONFIG)
			expect(result.Action).to.equal("Mantle")
		end)

		it("refuses above the mantle ceiling", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 9 }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("TooTallToMantle")
		end)

		it("refuses when the top is out of reach", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 6, Distance = 5 }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("MantleOutOfReach")
		end)

		it("refuses when there is nowhere to stand on top", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 6, HasStandingSpace = false }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("NoStandingSpace")
		end)

		it("refuses when a designer marked the surface unmantleable", function()
			local result = ObstacleClassifier.Classify(measure({ Height = 6, MantleAllowed = false }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("MantleNotAllowedHere")
		end)

		it("counts as a traversal", function()
			expect(ObstacleClassifier.IsTraversal(ObstacleClassifier.Classify(measure({ Height = 6 }), CONFIG))).to.equal(
				true
			)
		end)
	end)

	describe("ObstacleClassifier.Classify -- infinite measurements", function()
		-- The probe legitimately reports math.huge for "no top found in the sampled band" and "no far
		-- edge found in the sampled depth" -- both must fall out of the bands as a refusal rather than
		-- needing their own branch.
		it("treats an unbounded height as too tall to mantle", function()
			local result = ObstacleClassifier.Classify(measure({ Height = math.huge }), CONFIG)
			expect(result.Action).to.equal("None")
			expect(result.Reason).to.equal("TooTallToMantle")
		end)

		it("treats an unbounded depth as a mantle target when the height allows it", function()
			expect(ObstacleClassifier.Classify(measure({ Height = 3, Depth = math.huge }), CONFIG).Action).to.equal(
				"Mantle"
			)
		end)
	end)

	describe("ObstacleClassifier -- shipped band ordering", function()
		-- The one check against the real constants: the bands have to be strictly ordered or the
		-- classifier's if-ladder becomes unreachable in places, which no amount of retuning should ever
		-- be allowed to do silently.
		local shipped = ParkourConstants.Obstacle

		it("orders Step < Hop < Vault < Mantle", function()
			expect(shipped.StepMaxHeight < shipped.HopMaxHeight).to.equal(true)
			expect(shipped.HopMaxHeight < shipped.VaultMaxHeight).to.equal(true)
			expect(shipped.VaultMaxHeight < shipped.MantleMaxHeight).to.equal(true)
		end)

		it("keeps every band height positive", function()
			expect(shipped.StepMaxHeight > 0).to.equal(true)
			expect(shipped.VaultMaxDepth > 0).to.equal(true)
			expect(shipped.VaultMinSpeed > 0).to.equal(true)
		end)
	end)
end
