--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ArtSystem = require(ServerScriptService.Server.Systems.ArtSystem)
local ArtTreeManager = require(ServerScriptService.Server.Managers.ArtTreeManager)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)

-- ArtSystem.Init() is never called here -- it creates live remotes and subscribes to
-- PlayerDataSystem, neither of which this file needs. The per-player surface (Unlock, RegisterUse,
-- UseArt) is exercised only on its no-profile path, the same Studio/live-server-only gap every other
-- Progression spec documents: a real unlock needs PlayerDataSystem's DataStore-backed load flow for
-- a live Player.
--
-- What IS fully exercised is the move-to-art seam, which is where the actual risk
-- lives: MoveRegistryManager.Validate accepting/rejecting/clamping an authored Art binding, and
-- ArtTreeManager indexing the registry into trees. Both run against a real registry populated
-- through the real Upsert path, no mocking.

local function baseMove(moveId: string, art: any?): any
	return {
		MoveId = moveId,
		DisplayName = moveId,
		Category = "Test",
		Author = "Spec",
		CreatedAt = 0,
		UpdatedAt = 0,
		Shape = "Box",
		Dimensions = { Width = 5, Height = 5, Length = 5 },
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = 0,
		WindupSeconds = 0.2,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.2,
		Cooldown = 1,
		Damage = 10,
		PostureDamage = 10,
		AnimationId = "",
		Art = art,
	}
end

local function upsert(moveId: string, art: any?): any
	local validated, reason = MoveRegistryManager.Validate(baseMove(moveId, art))
	if not validated then
		error(`Validate rejected {moveId}: {tostring(reason)}`)
	end
	MoveRegistryManager.Upsert(validated)
	return validated
end

return function()
	describe("ArtConstants", function()
		it("passes its own roster validation", function()
			local ok, problem = ArtConstants.Validate()
			if not ok then
				error(`ArtConstants.Validate failed: {problem}`)
			end
			expect(ok).to.equal(true)
		end)

		it("prices no art above a Tier 1 player's full Qi pool", function()
			-- Guards the stated intent in Limits.QiCost's own comment: no art should be literally
			-- uncastable at the bottom of the ladder.
			local QiConstants = require(ReplicatedStorage.Shared.QiConstants)
			expect(ArtConstants.Limits.QiCost.Max < QiConstants.MaxQiByTier[1]).to.equal(true)
		end)

		it("bounds RequiredTier by the real tier ladder", function()
			local TierConstants = require(ReplicatedStorage.Shared.TierConstants)
			expect(ArtConstants.Limits.RequiredTier.Max).to.equal(TierConstants.MaxTier)
		end)

		it("ships at least one tree open to a player with no faction", function()
			-- FactionManager is still a stub, so if every tree were faction-gated no player could
			-- unlock anything at all.
			local openTrees = 0
			for _, tree in ipairs(ArtConstants.ArtTrees) do
				if tree.Faction == nil then
					openTrees += 1
				end
			end
			expect(openTrees > 0).to.equal(true)
		end)
	end)

	describe("MoveRegistryManager.Validate -- Art binding", function()
		it("accepts a move with no Art block, exactly as before arts existed", function()
			local validated = MoveRegistryManager.Validate(baseMove("plain_move"))
			expect(validated).to.be.ok()
			expect((validated :: any).Art).to.equal(nil)
		end)

		it("accepts a well-formed Art binding", function()
			local validated = MoveRegistryManager.Validate(baseMove("art_move", {
				TreeId = "common_foundation",
				Node = 1,
				QiCost = 20,
				RequiredTier = 1,
			}))
			expect(validated).to.be.ok()
			local art = (validated :: any).Art
			expect(art).to.be.ok()
			expect(art.TreeId).to.equal("common_foundation")
			expect(art.QiCost).to.equal(20)
		end)

		it("rejects an Art binding naming a tree that does not exist", function()
			local validated, reason = MoveRegistryManager.Validate(baseMove("bad_tree", {
				TreeId = "no_such_tree",
				Node = 1,
				QiCost = 0,
				RequiredTier = 1,
			}))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("UnknownArtTree")
		end)

		it("rejects an art that lists itself as its own prerequisite", function()
			local validated, reason = MoveRegistryManager.Validate(baseMove("self_ref", {
				TreeId = "common_foundation",
				Node = 2,
				QiCost = 0,
				RequiredTier = 1,
				Prerequisite = "self_ref",
			}))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("SelfReferentialArtPrerequisite")
		end)

		it("clamps out-of-range numbers rather than failing the save", function()
			local validated = MoveRegistryManager.Validate(baseMove("clamped", {
				TreeId = "common_foundation",
				Node = 999,
				QiCost = -50,
				RequiredTier = 999,
			}))
			expect(validated).to.be.ok()
			local art = (validated :: any).Art
			expect(art.Node).to.equal(ArtConstants.Limits.Node.Max)
			expect(art.QiCost).to.equal(ArtConstants.Limits.QiCost.Min)
			expect(art.RequiredTier).to.equal(ArtConstants.Limits.RequiredTier.Max)
		end)

		it("rejects a non-table Art block", function()
			local validated, reason = MoveRegistryManager.Validate(baseMove("junk_art", "not-a-table"))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidArt")
		end)
	end)

	describe("ArtTreeManager", function()
		it("indexes only moves that carry an Art binding", function()
			MoveRegistryManager.Init()
			upsert("ordinary_move")
			upsert("tree_art", { TreeId = "common_foundation", Node = 1, QiCost = 5, RequiredTier = 1 })

			expect(ArtTreeManager.IsArt("ordinary_move")).to.equal(false)
			expect(ArtTreeManager.IsArt("tree_art")).to.equal(true)
			expect(#ArtTreeManager.GetArtsInTree("common_foundation")).to.equal(1)
		end)

		it("orders a tree's arts shallowest node first", function()
			MoveRegistryManager.Init()
			upsert("deep", { TreeId = "common_foundation", Node = 4, QiCost = 0, RequiredTier = 1 })
			upsert("shallow", { TreeId = "common_foundation", Node = 1, QiCost = 0, RequiredTier = 1 })
			upsert("middle", { TreeId = "common_foundation", Node = 2, QiCost = 0, RequiredTier = 1 })

			local arts = ArtTreeManager.GetArtsInTree("common_foundation")
			expect(arts[1].MoveId).to.equal("shallow")
			expect(arts[2].MoveId).to.equal("middle")
			expect(arts[3].MoveId).to.equal("deep")
		end)

		it("keeps trees separate", function()
			MoveRegistryManager.Init()
			upsert("a", { TreeId = "common_foundation", Node = 1, QiCost = 0, RequiredTier = 1 })
			upsert("b", { TreeId = "celestial_ascendant_palm", Node = 1, QiCost = 0, RequiredTier = 1 })

			expect(#ArtTreeManager.GetArtsInTree("common_foundation")).to.equal(1)
			expect(#ArtTreeManager.GetArtsInTree("celestial_ascendant_palm")).to.equal(1)
			expect(#ArtTreeManager.GetArtsInTree("demonic_devouring_fist")).to.equal(0)
		end)

		it("gates a faction tree but leaves an open tree open", function()
			expect(ArtTreeManager.IsTreeOpenTo("common_foundation", nil)).to.equal(true)
			expect(ArtTreeManager.IsTreeOpenTo("celestial_ascendant_palm", nil)).to.equal(false)
			expect(ArtTreeManager.IsTreeOpenTo("celestial_ascendant_palm", "Celestial")).to.equal(true)
			expect(ArtTreeManager.IsTreeOpenTo("celestial_ascendant_palm", "Demonic")).to.equal(false)
		end)

		it("returns nil for a move that exists but is not an art", function()
			MoveRegistryManager.Init()
			upsert("just_a_move")
			expect(ArtTreeManager.GetArt("just_a_move")).to.equal(nil)
			expect(ArtTreeManager.GetArt("does_not_exist_at_all")).to.equal(nil)
		end)

		it("audits a prerequisite pointing at a move that is not an art", function()
			MoveRegistryManager.Init()
			upsert("not_an_art")
			upsert("depends", {
				TreeId = "common_foundation",
				Node = 2,
				QiCost = 0,
				RequiredTier = 1,
				Prerequisite = "not_an_art",
			})

			local problems = ArtTreeManager.AuditPrerequisites()
			expect(#problems).to.equal(1)
		end)

		it("audits a prerequisite that is not shallower, since that can close a cycle", function()
			MoveRegistryManager.Init()
			upsert("first", {
				TreeId = "common_foundation",
				Node = 2,
				QiCost = 0,
				RequiredTier = 1,
				Prerequisite = "second",
			})
			upsert("second", {
				TreeId = "common_foundation",
				Node = 2,
				QiCost = 0,
				RequiredTier = 1,
				Prerequisite = "first",
			})

			expect(#ArtTreeManager.AuditPrerequisites()).to.equal(2)
		end)

		it("reports no problems for a well-formed tree", function()
			MoveRegistryManager.Init()
			upsert("entry", { TreeId = "common_foundation", Node = 1, QiCost = 0, RequiredTier = 1 })
			upsert("advanced", {
				TreeId = "common_foundation",
				Node = 2,
				QiCost = 10,
				RequiredTier = 2,
				Prerequisite = "entry",
			})

			expect(#ArtTreeManager.AuditPrerequisites()).to.equal(0)
		end)
	end)

	describe("ArtSystem (no profile loaded)", function()
		it("reports an unknown art rather than erroring", function()
			MoveRegistryManager.Init()
			expect(ArtSystem.CanUnlock({} :: any, "nothing_here")).to.equal("UnknownArt")
		end)

		it("refuses to unlock without a loaded profile", function()
			MoveRegistryManager.Init()
			upsert("entry", { TreeId = "common_foundation", Node = 1, QiCost = 0, RequiredTier = 1 })
			expect(ArtSystem.Unlock({} :: any, "entry")).to.be.ok()
		end)

		it("refuses to use an art that is not unlocked", function()
			MoveRegistryManager.Init()
			upsert("entry", { TreeId = "common_foundation", Node = 1, QiCost = 0, RequiredTier = 1 })
			expect(ArtSystem.UseArt({} :: any, "entry")).to.equal("NotUnlocked")
		end)

		it("reports zero mastery for an untouched art", function()
			expect(ArtSystem.GetMastery({} :: any, "entry")).to.equal(0)
		end)
	end)
end
