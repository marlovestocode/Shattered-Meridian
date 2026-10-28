--!strict
--[[
	WorldArchitect/WorldPanel.lua

	Owns: the World tab -- where the working world stands against what is saved (unpublished changes, the budget, the
	Live generation), publishing it to the Live slot every server loads at boot, saving it as a named draft, and the
	saved slots with their snapshots: load a slot, restore one of its earlier generations, delete a draft.

	EVERY DESTRUCTIVE ACTION IS ARMED (two presses): publish, load, restore, delete. A load or restore also saves the
	working world to the Autosave slot first -- the server does that and refuses the load if it cannot -- so the prose
	under the buttons can promise it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Kit = require(script.Parent.Parent.DevMenu.Kit)

local Style = require(script.Parent.Style)
local WorldArchitectTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle

local peek = Fusion.peek
local Persistence = ArchitectConstants.Persistence

local function when(timestamp: number): string
	if timestamp <= 0 then
		return "?"
	end
	return os.date("!%Y-%m-%d %H:%M UTC", timestamp) :: string
end

local function WorldPanel(scope: Scope, handle: Handle, visible: Fusion.UsedAs<boolean>): ScrollingFrame
	local note = scope:Value("")
	local draftName = scope:Value("")
	local focusedSlot = scope:Value(nil :: string?)

	local server = handle.Server
	local function fact(pick: (WorldArchitectTypes.ServerStatus) -> string): Fusion.Computed<string>
		return scope:Computed(function(use)
			local s = use(server)
			return if s then pick(s) else "—"
		end)
	end

	local slotRows = scope:ForPairs(handle.Slots, function(_use, inner: Scope, index: number, slot: any)
		local generations = slot.Generations or {}
		local latest = generations[#generations]
		local detail = if latest
			then `{#generations} saves · latest {when(latest.SavedAt)} by {latest.SavedBy} · {latest.Nodes} nodes`
			else "empty"
		local focused = inner:Computed(function(use)
			return use(focusedSlot) == slot.Name
		end)
		local row = inner:New "TextButton" {
			Name = "Slot",
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundColor3 = Tokens.Color.FactionCelestial,
			BackgroundTransparency = inner:Computed(function(use)
				return if use(focused) then 0.84 else 1
			end),
			AutoButtonColor = false,
			Text = "",
			LayoutOrder = index,
			[Fusion.OnEvent "Activated"] = function()
				focusedSlot:set(if peek(focusedSlot) == slot.Name then nil else slot.Name)
			end,
			[Fusion.Children] = {
				Label(inner, {
					Text = if slot.Name == Persistence.LiveSlot then "Live  (loaded at every boot)" else slot.Name,
					Scale = "Body",
					Color = if slot.Name == Persistence.LiveSlot
						then Tokens.Color.FactionCelestial
						else Tokens.Color.TextPrimary,
					Position = UDim2.fromOffset(Tokens.Space.S, 3),
					Size = UDim2.new(1, -Tokens.Space.S, 0, Tokens.Type.Body.Size + 4),
					TextTruncate = Enum.TextTruncate.AtEnd,
				}),
				Label(inner, {
					Text = detail,
					Scale = "Detail",
					Color = Style.Quiet,
					Position = UDim2.fromOffset(Tokens.Space.S, 21),
					Size = UDim2.new(1, -Tokens.Space.S, 0, Tokens.Type.Detail.Size + 4),
					TextTruncate = Enum.TextTruncate.AtEnd,
				}),
			},
		}
		return index, row
	end)

	local focusedGenerations = scope:Computed(function(use)
		local name = use(focusedSlot)
		for _, slot in use(handle.Slots) do
			if slot.Name == name then
				-- Newest first; the newest IS the slot (Load), the rest are snapshots (Restore).
				local list = {}
				for i = #slot.Generations, 1, -1 do
					table.insert(list, slot.Generations[i])
				end
				return list
			end
		end
		return {}
	end)
	local hasFocusedSlot = scope:Computed(function(use)
		return use(focusedSlot) ~= nil
	end)

	local generationRows = scope:ForPairs(
		focusedGenerations,
		function(_use, inner: Scope, index: number, generation: any)
			local noteText = if generation.Note ~= "" then ` — {generation.Note}` else ""
			return index,
				Kit.Row(inner, 100 + index, {
					Label(inner, {
						Text = `#{generation.Gen} · {when(generation.SavedAt)} · {generation.Nodes} nodes{noteText}`,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(0.62, 1),
						TextTruncate = Enum.TextTruncate.AtEnd,
						LayoutOrder = 1,
					}),
					Kit.Armed(inner, {
						Idle = if index == 1 then "LOAD" else "RESTORE",
						Armed = "CONFIRM",
						Order = 2,
						Size = UDim2.new(0.38, -Tokens.Space.S, 1, 0),
						OnConfirm = function()
							handle.Fire({
								Kind = "LoadSlot",
								Slot = peek(focusedSlot),
								Gen = if index == 1 then nil else generation.Gen,
							})
						end,
					}),
				})
		end
	)

	return Kit.Page(scope, "World", visible, {
		Kit.Heading(scope, "WORKING WORLD", 1),
		Kit.Stat(
			scope,
			"State",
			fact(function(s)
				if not s.Ready then
					return "Loading the Live world"
				end
				if not s.StorageAvailable then
					return "No storage — nothing can be saved"
				end
				return if s.Unpublished then "Unpublished changes" else "Matches the Live slot"
			end),
			2,
			nil,
			scope:Computed(function(use)
				local s = use(server)
				return if s and s.Unpublished then Tokens.Color.Warning else Tokens.Color.Positive
			end)
		),
		Kit.Meter(scope, {
			Caption = "Nodes",
			Value = scope:Computed(function(use)
				local s = use(server)
				return if s then s.Count else 0
			end),
			Max = ArchitectConstants.Limits.MaxNodes,
			Text = fact(function(s)
				return `{s.Count} / {ArchitectConstants.Limits.MaxNodes}`
			end),
			Color = Tokens.Color.FactionCelestial,
			Order = 3,
		}),
		Kit.Stat(
			scope,
			"Live save",
			fact(function(s)
				return if s.LiveGeneration then `#{s.LiveGeneration}` else "never published"
			end),
			4
		),
		Style.Prose(
			scope,
			"Edits change this server's world immediately. They reach new servers only when published to Live.",
			5
		),
		Kit.Holder(
			scope,
			"Note",
			6,
			TextField(scope, {
				Text = note,
				PlaceholderText = "Note for this save (optional)",
				MaxLength = 80,
				Size = UDim2.new(1, 0, 0, Kit.ButtonHeight),
			})
		),
		Kit.Armed(scope, {
			Idle = "PUBLISH TO LIVE",
			Armed = "CONFIRM PUBLISH",
			Order = 7,
			OnConfirm = function()
				handle.Fire({ Kind = "SaveSlot", Slot = Persistence.LiveSlot, Note = peek(note) })
			end,
		}),
		Kit.Heading(scope, "DRAFTS", 10),
		Kit.Holder(
			scope,
			"DraftName",
			11,
			TextField(scope, {
				Text = draftName,
				PlaceholderText = "Draft name (letters, digits, - _)",
				MaxLength = Persistence.MaxSlotNameLength,
				Size = UDim2.new(1, 0, 0, Kit.ButtonHeight),
			})
		),
		Kit.Button(scope, {
			Text = "SAVE AS DRAFT",
			Order = 12,
			Disabled = scope:Computed(function(use)
				local name = use(draftName)
				return name == "" or name == Persistence.LiveSlot
			end),
			OnActivated = function()
				handle.Fire({ Kind = "SaveSlot", Slot = peek(draftName), Note = peek(note) })
			end,
		}),
		Kit.Heading(scope, "SAVED SLOTS", 20),
		Kit.Button(scope, {
			Text = "REFRESH",
			Order = 21,
			OnActivated = function()
				handle.Fire({ Kind = "ListSlots" })
			end,
		}),
		Style.Prose(scope, "Select a slot to see its saves. Loading first saves the working world to Autosave.", 22),
		Kit.Group(scope, 23, { slotRows :: any }, nil, 0),
		Kit.Heading(scope, "SAVES IN SLOT", 30, hasFocusedSlot),
		Kit.Group(scope, 31, { generationRows :: any }, hasFocusedSlot, Tokens.Space.XS),
		Kit.Armed(scope, {
			Idle = "DELETE THIS SLOT",
			Armed = "CONFIRM DELETE",
			Order = 32,
			Visible = scope:Computed(function(use)
				local name = use(focusedSlot)
				return name ~= nil and name ~= Persistence.LiveSlot
			end),
			OnConfirm = function()
				handle.Fire({ Kind = "DeleteSlot", Slot = peek(focusedSlot) })
				focusedSlot:set(nil)
			end,
		}),
	})
end

return WorldPanel
