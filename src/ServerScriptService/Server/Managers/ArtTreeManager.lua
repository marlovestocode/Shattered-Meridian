--!strict
--[[
	ArtTreeManager.lua

	Owns: the art tree structure -- what trees exist, which arts sit in each, and in what order.
	The "Manager" half of this codebase's Manager/System pairing (mirrors MoveRegistryManager/
	MoveEditorSystem and BloodlineManager/BloodlineSystem); ArtSystem.lua is the "System" half that
	owns a player's progress through these trees.

	Does not own: per-player unlock or mastery state (ArtSystem), the move data an art is built on
	(MoveRegistryManager owns the registry; this module only indexes it), or the tree roster's
	content (Shared/ArtConstants.ArtTrees).

	THE INDEX IS DERIVED, NEVER STORED. Which arts live in a tree is computed from
	MoveRegistryManager on every query rather than cached at Init. That is deliberate: moves are
	authored live in the Move Editor and hot-applied through MoveRegistryManager.Upsert (that
	module's whole reason for keeping DataStore I/O out), so a cached index would go stale the moment
	an admin saved an art -- and would do it silently, showing a tree that no longer matches the
	registry. The cost is a scan of the move table per query, which is bounded by the authored move
	count and happens on menu opens and unlocks, never in a combat path.

	An art is simply a move whose MoveTypes.MoveArtBinding is present -- see ArtConstants.lua's
	header for why arts are moves rather than a parallel ability object. An art's ArtId IS its
	MoveId; there is no second identity to keep in sync.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MoveRegistryManager = require(script.Parent.Parent.Combat.MoveRegistryManager)

local logger = Logger.scope("ArtTreeManager")

local ArtTreeManager = {}

export type ArtTree = {
	TreeId: string,
	DisplayName: string,
	Faction: Types.Faction?,
	Description: string,
}

-- Every tree in the roster, in authored order.
function ArtTreeManager.GetTrees(): { ArtTree }
	local trees: { ArtTree } = {}
	for _, tree in ipairs(ArtConstants.ArtTrees) do
		table.insert(trees, {
			TreeId = tree.TreeId,
			DisplayName = tree.DisplayName,
			Faction = tree.Faction,
			Description = tree.Description,
		})
	end
	return trees
end

function ArtTreeManager.GetTree(treeId: string): ArtTree?
	for _, tree in ipairs(ArtConstants.ArtTrees) do
		if tree.TreeId == treeId then
			return {
				TreeId = tree.TreeId,
				DisplayName = tree.DisplayName,
				Faction = tree.Faction,
				Description = tree.Description,
			}
		end
	end
	return nil
end

-- The move behind `artId`, or nil if that move doesn't exist OR exists but isn't an art. Both cases
-- collapse to nil deliberately: a caller asking for an art has no use for a move that isn't one, and
-- distinguishing them would just push the same check outward to every call site.
function ArtTreeManager.GetArt(artId: string): MoveTypes.MoveDefinition?
	local move = MoveRegistryManager.Get(artId)
	if not move or not move.Art then
		return nil
	end
	return move
end

function ArtTreeManager.IsArt(moveId: string): boolean
	return ArtTreeManager.GetArt(moveId) ~= nil
end

-- Every art in `treeId`, shallowest node first. Ties broken by MoveId so the order is stable across
-- calls and across servers -- a tree whose rows reshuffle between menu opens reads as broken, and
-- pairs() over the registry has no inherent order to inherit.
function ArtTreeManager.GetArtsInTree(treeId: string): { MoveTypes.MoveDefinition }
	local arts: { MoveTypes.MoveDefinition } = {}
	for _, move in ipairs(MoveRegistryManager.List()) do
		local art = move.Art
		if art and art.TreeId == treeId then
			table.insert(arts, move)
		end
	end
	table.sort(arts, function(a, b)
		local artA = a.Art :: MoveTypes.MoveArtBinding
		local artB = b.Art :: MoveTypes.MoveArtBinding
		if artA.Node == artB.Node then
			return a.MoveId < b.MoveId
		end
		return artA.Node < artB.Node
	end)
	return arts
end

-- Whether `faction` may walk `treeId` at all. A tree with no Faction is open to everyone, which is
-- what lets a player FactionManager hasn't assigned yet (it is still a stub) have somewhere to
-- start -- see ArtConstants.ArtTrees' own header.
function ArtTreeManager.IsTreeOpenTo(treeId: string, faction: Types.Faction?): boolean
	local tree = ArtTreeManager.GetTree(treeId)
	if not tree then
		return false
	end
	if tree.Faction == nil then
		return true
	end
	return tree.Faction == faction
end

-- The cross-registry checks validateArt deliberately can't make on its own, because it validates one
-- move at a time and has no guarantee the move it references has loaded yet (see that function's
-- header). Run against the whole registry, this catches a prerequisite that names a move which
-- doesn't exist, isn't an art, or sits in a different tree, plus a prerequisite cycle.
--
-- Reports rather than repairs. These are authoring mistakes in live admin data, and silently
-- dropping a prerequisite would quietly hand a player an art they hadn't earned -- exactly the wrong
-- direction to fail. ArtSystem.CanUnlock independently refuses to unlock past a broken prerequisite,
-- so a bad edit costs an unreachable art, never a free one.
function ArtTreeManager.AuditPrerequisites(): { string }
	local problems: { string } = {}
	for _, move in ipairs(MoveRegistryManager.List()) do
		local art = move.Art
		if art and art.Prerequisite then
			local prerequisite = ArtTreeManager.GetArt(art.Prerequisite)
			if not prerequisite then
				table.insert(problems, `{move.MoveId}: prerequisite "{art.Prerequisite}" is not an art`)
			elseif (prerequisite.Art :: MoveTypes.MoveArtBinding).TreeId ~= art.TreeId then
				table.insert(problems, `{move.MoveId}: prerequisite "{art.Prerequisite}" is in another tree`)
			elseif (prerequisite.Art :: MoveTypes.MoveArtBinding).Node >= art.Node then
				-- Not merely untidy: a prerequisite at the same or a deeper node can close a cycle,
				-- and a cycle makes every art in it permanently unreachable.
				table.insert(problems, `{move.MoveId}: prerequisite "{art.Prerequisite}" is not shallower`)
			end
		end
	end
	return problems
end

function ArtTreeManager.Init(): ()
	local rosterOk, rosterProblem = ArtConstants.Validate()
	if not rosterOk then
		logger:warn("ArtConstants roster failed validation", { problem = rosterProblem })
	end

	-- DELIBERATELY NO AUDIT HERE, for the same reason BloodlineManager.Init states: this Manager
	-- boots at Main.server.lua step 160, before MoveRegistryManager has even Init'd (223) and long
	-- before MoveEditorSystem loads the persisted moves arts are derived from (358, asynchronously).
	-- The audit that used to sit here saw an empty registry every boot and logged clean -- a check
	-- that cannot fail reads as a check that passed. AuditPrerequisites stays public and is called by
	-- MoveEditorSystem.loadPersistedMoves once the moves are actually in.

	logger:info("ArtTreeManager.Init() complete", { trees = #ArtConstants.ArtTrees })
end

return ArtTreeManager :: Types.SystemModule
