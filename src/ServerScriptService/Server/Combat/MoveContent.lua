--!strict
--[[
	MoveContent.lua

	Owns: "the move combat would actually throw for this id" -- the one binding of Server/Data/ContentRegistry for moves. Custom
	(MoveRegistryManager) over Default (DefaultMoveRegistry). A custom move sharing an id with a Default one is the more specific
	intent, so it wins; the editor never creates one (a generated id never carries the "default:" prefix), but a spec does, to
	stand a custom move in for a weapon stage.

	`Resolve(id)` also answers WHICH layer won ("Custom" | "Default" -- the Move Editor's MoveSource), so the editor edits the move
	combat would throw. DefaultMoveRegistry.Get composes its shipped files and overrides fresh on every call, so nothing here is
	ever stale.

	Does not own: writing a move (MoveRegistryManager.Upsert/Delete, DefaultMoveRegistry's overrides, via MoveEditorSystem),
	the built roster (DefaultMoveRegistry.GetBuilt), or persistence. Readers that deliberately want ONE layer keep asking it
	directly: arts and realms are custom moves only (ArtTreeManager, DomainSystem), and the editor's "saved state" is per layer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local ContentRegistry = require(script.Parent.Parent.Data.ContentRegistry)
local DefaultMoveRegistry = require(script.Parent.DefaultMoveRegistry)
local MoveRegistryManager = require(script.Parent.MoveRegistryManager)

export type MoveSource = "Custom" | "Default"

local MoveContent = ContentRegistry.New({
	Kind = "Move",
	IdOf = function(move: MoveTypes.MoveDefinition): string
		return move.MoveId
	end,
	Layers = {
		{
			Name = "Custom",
			Get = MoveRegistryManager.Get,
			List = MoveRegistryManager.List,
			OnChanged = MoveRegistryManager.OnChanged,
		},
		{
			Name = "Default",
			Get = DefaultMoveRegistry.Get,
			List = DefaultMoveRegistry.List,
			OnChanged = DefaultMoveRegistry.OnChanged,
		},
	},
})

return MoveContent
