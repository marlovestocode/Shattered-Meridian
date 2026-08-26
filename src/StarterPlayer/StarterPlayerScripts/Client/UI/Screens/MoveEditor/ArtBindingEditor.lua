--!strict
--[[
	ArtBindingEditor.lua

	Owns: the Move Editor's Art section -- the "convert an existing move into an art" surface, which is
	an enable Toggle plus four fields writing one MoveTypes.MoveArtBinding onto the draft.

	Deliberately the LAST authoring section, and deliberately this small, because that IS the whole
	workflow: everything an art DOES was already authored in the sections above it. Flipping Enable
	adds the binding; the move is otherwise untouched, which is exactly why an existing, already-tuned
	move can become an art without being rebuilt. See ArtConstants.lua's own header for why an art is a
	move rather than a parallel ability object.

	Defaults on enable are the shallowest legal art (node 1, no prerequisite, tier 1, a modest Qi cost)
	rather than empty fields: node 1 is always unlockable, so a designer who flips this and saves
	immediately gets a working entry-level art rather than something gated behind nothing.

	Every commit goes through applyArt below rather than DraftBinding.Apply directly, for the reason
	EffectsEditor.lua's own header spells out: Apply's clone is SHALLOW, so writing straight through
	`draft.Art.QiCost` would also rewrite the previous draft object MoveList.lua's cache still holds.

	Does not own: what an art COSTS to unlock or what mastery does with it (ArtSystem), whether the
	tree exists (MoveRegistryManager.validateArt rejects an unknown TreeId outright, and clamps
	Node/QiCost/RequiredTier into ArtConstants.Limits rather than rejecting them), or whether a
	prerequisite resolves -- see the Prerequisite field's own comment for why that check cannot live
	here and where it does live.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local Dropdown = require(script.Parent.Parent.Parent.Components.Dropdown)
local Toggle = require(script.Parent.Parent.Parent.Components.Toggle)
local NumericField = require(script.Parent.Parent.Parent.Components.NumericField)
local DraftBinding = require(script.Parent.DraftBinding)

type Scope = Fusion.Scope<typeof(Fusion)>
type DraftContext = DraftBinding.DraftContext

local ArtBindingEditorModule = {}

-- Clone-then-mutate the Art binding. MoveArtBinding nests nothing, so one flat clone is the whole
-- job -- the same shape MoveTypes.Clone uses for it, and for the same reason.
local function applyArt(context: DraftContext, mutate: (MoveTypes.MoveArtBinding) -> ()): ()
	DraftBinding.Apply(context, function(draft)
		local current = draft.Art
		if not current then
			return
		end
		local updated = table.clone(current)
		mutate(updated)
		draft.Art = updated
	end)
end

function ArtBindingEditorModule.Build(scope: Scope, context: DraftContext): { Instance }
	local firstTreeId = ArtConstants.ArtTrees[1].TreeId

	local hasArt = DraftBinding.Field(context, scope, function(draft): boolean
		return draft.Art ~= nil
	end, false)
	local treeId = DraftBinding.Field(context, scope, function(draft): string
		return if draft.Art then draft.Art.TreeId else firstTreeId
	end, firstTreeId)
	local node = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Art then draft.Art.Node else 1
	end, 1)
	local qiCost = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Art then draft.Art.QiCost else 15
	end, 15)
	local requiredTier = DraftBinding.Field(context, scope, function(draft): number
		return if draft.Art then draft.Art.RequiredTier else 1
	end, 1)

	-- Built once from the roster, not per render -- the tree list is static content
	-- (ArtConstants.ArtTrees) and cannot change while the editor is open.
	local treeOptions: { { Value: string, Text: string } } = {}
	for _, tree in ipairs(ArtConstants.ArtTrees) do
		table.insert(treeOptions, { Value = tree.TreeId, Text = tree.DisplayName })
	end

	local limits = ArtConstants.Limits

	return {
		Toggle(scope, {
			Label = "Enable as Art",
			Value = hasArt,
			LayoutOrder = 3,
			OnChanged = function(enabled: boolean)
				DraftBinding.Apply(context, function(draft)
					draft.Art = if enabled
						then {
							TreeId = firstTreeId,
							Node = 1,
							QiCost = 15,
							RequiredTier = 1,
							Prerequisite = nil,
						}
						else nil
				end)
			end,
		}),
		DraftBinding.VisibleWhen(
			scope,
			4,
			hasArt,
			Dropdown.Mount(scope, {
				Label = "Tree",
				Options = treeOptions,
				Value = treeId,
				OnChanged = function(newTreeId: string)
					applyArt(context, function(art)
						art.TreeId = newTreeId
						-- A prerequisite only ever refers to an art in the SAME tree
						-- (ArtTreeManager.AuditPrerequisites treats a cross-tree one as a defect), so
						-- moving trees clears it rather than silently carrying a now-invalid reference.
						art.Prerequisite = nil
					end)
				end,
			})
		),
		DraftBinding.Row(scope, 5, 3, {
			NumericField.Mount(scope, {
				Label = "Node",
				Hint = "Depth in the tree. Node 1 is an entry form and is never gated behind a prerequisite.",
				Value = node,
				Min = limits.Node.Min,
				Max = limits.Node.Max,
				Steps = { 1 },
				Decimals = 0,
				Visible = hasArt,
				OnChanged = function(value: number)
					applyArt(context, function(art)
						art.Node = value
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Qi Cost",
				Hint = "Spent from the caster's pool on every use. 0 is legal.",
				Value = qiCost,
				Min = limits.QiCost.Min,
				Max = limits.QiCost.Max,
				Steps = { 1, 5 },
				Decimals = 0,
				Visible = hasArt,
				OnChanged = function(value: number)
					applyArt(context, function(art)
						art.QiCost = value
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Required Tier",
				Hint = "Minimum tier before a player can unlock this art.",
				Value = requiredTier,
				Min = limits.RequiredTier.Min,
				Max = limits.RequiredTier.Max,
				Steps = { 1 },
				Decimals = 0,
				Visible = hasArt,
				OnChanged = function(value: number)
					applyArt(context, function(art)
						art.RequiredTier = value
					end)
				end,
			}),
		}),
		-- Prerequisite is a free-text MoveId rather than a dropdown of sibling arts, and that is a
		-- deliberate v1 limit rather than an oversight: this panel only ever holds ONE move (the draft),
		-- and the list of every other art in the same tree lives in the registry, which this file has no
		-- reference to and would have to reach through a new remote to read. The server validates the
		-- value either way -- a self-reference is rejected outright at save, and a prerequisite that is
		-- missing, in another tree, or not shallower is reported by ArtTreeManager.AuditPrerequisites --
		-- so a typo costs an unreachable art that an audit names, never a wrongly-granted one.
		DraftBinding.TextRow(scope, context, {
			Label = "Prerequisite Art Id",
			LayoutOrder = 6,
			Visible = hasArt,
			Get = function(draft)
				return if draft.Art and draft.Art.Prerequisite then draft.Art.Prerequisite else ""
			end,
			OnCommit = function(text: string)
				applyArt(context, function(art)
					-- Trimmed, and blank means "no prerequisite" rather than an empty-string id: an art
					-- whose prerequisite is "" would fail validateArt's isNonEmptyString check and take
					-- the whole save down over a stray space.
					local trimmed = text:match("^%s*(.-)%s*$") or ""
					art.Prerequisite = if trimmed == "" then nil else trimmed
				end)
			end,
		}),
	}
end

return ArtBindingEditorModule
