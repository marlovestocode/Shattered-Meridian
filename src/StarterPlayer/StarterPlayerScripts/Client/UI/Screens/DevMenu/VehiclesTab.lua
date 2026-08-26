--!strict
--[[
	DevMenu/VehiclesTab.lua

	Owns: the Vehicles tab's four sections -- where the registry resolved (plus anything it rejected),
	the catalog with a Spawn button per vehicle, the berth picker that spawn targets, and the live list
	with a Despawn button per row.

	ITS OWN FILE, unlike the other four tabs, which live inline in ContentArea.lua. That file is
	already ~1580 lines and its own header records that it got that way by absorbing one screen's
	worth of controls at a time; this tab is the first one with three dynamic lists in it, so adding
	it inline would have added the most code of any tab to the file least able to take it. Same
	Sidebar/ContentArea precedent, one level down: ContentArea still owns the tab strip, the
	ScrollingFrame and the visibility Computed -- this module hands back only the section Instances
	that go inside it.

	THE BERTH PICKER IS LOCAL STATE, THE ONLY LOCAL STATE HERE. Which berth a spawn targets is a
	choice the admin makes in this panel and that the server has no opinion about until Spawn is
	pressed, so it is a plain Fusion.Value owned by this module. Everything else on this tab is
	server-authoritative and is only ever displayed -- the same "never let the client guess a
	server-wide value" contract ContentArea's own HitboxDebugActive/DummyGuardActive already keep, and
	the reason a spawn does not optimistically add a row to the live list: the server may have evicted
	something to make room, and a list that showed the spawn but not the eviction would be wrong in
	the one moment an admin is looking at it.

	ROWS ARE ALREADY-FORMATTED STRINGS. Every number (a footprint in studs, an age, a position) is
	turned into text by DevMenuClient.lua, per this screen's own "already-computed value in,
	presentation out" boundary -- see DevMenu/Types.lua's header. This module never sees a Vector3.

	Does not own: fetching anything (DevMenuClient.lua drives every signal here), authorization
	(Server/Systems/VehicleManager.lua re-checks it regardless of whether this tab is even visible),
	or the tab strip and scroll area (ContentArea.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Section = require(script.Parent.Parent.Parent.Components.Section)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)

local DevMenuTypes = require(script.Parent.Types)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

local VehiclesTab = {}

-- Height of a two-line list row: a name line and a detail line, plus the gap between them. Named
-- rather than inlined because all three lists use it and a row that disagrees with its siblings by a
-- pixel is visible in a stacked list.
local ROW_HEIGHT = 44

-- The action button's share of a row. Fixed offset rather than a scale so the button is the same
-- width in the catalog list and the live list, whose name columns are different lengths.
local ROW_ACTION_WIDTH = 96

-- One list row: a two-line text block on the left, one action button pinned right. Shared by the
-- catalog and live lists, which differ only in their text and their button's label -- writing it
-- twice is how the two would drift into looking like two different components.
local function listRow(
	scope: Scope,
	nameText: string,
	detailText: string,
	actionText: string,
	layoutOrder: number,
	onActivated: () -> ()
): Frame
	return scope:New "Frame" {
		Name = "Row",
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "Frame" {
				Name = "Text",
				Size = UDim2.new(1, -(ROW_ACTION_WIDTH + Tokens.Space.S), 1, 0),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Label(scope, {
						Text = nameText,
						Scale = "Body",
						Color = Tokens.Color.TextPrimary,
						Size = UDim2.new(1, 0, 0, 20),
						LayoutOrder = 1,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
					Label(scope, {
						Text = detailText,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.new(1, 0, 0, 16),
						LayoutOrder = 2,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
				},
			},
			Button(scope, {
				Text = actionText,
				Size = UDim2.fromOffset(ROW_ACTION_WIDTH, Tokens.Control.RowHeight),
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				OnActivated = onActivated,
			}),
		},
	} :: Frame
end

-- A plain one-line note used for every empty state and for the registry readout. Its own helper
-- because "the list is empty" appears three times on this tab and each one has to say something
-- DIFFERENT and specific -- an empty catalog and an empty live list are completely unrelated
-- situations, and one shared "Nothing here" would hide that.
local function noteLabel(scope: Scope, text: Fusion.UsedAs<string>, layoutOrder: number): TextLabel
	return Label(scope, {
		Text = text,
		Scale = "Detail",
		Color = Tokens.Color.TextSecondary,
		-- Width from the parent, height from the text -- see Label.AutoHeight.
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = layoutOrder,
		AutoHeight = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

function VehiclesTab.Build(scope: Scope): DevMenuTypes.VehiclesTabHandle
	local catalogDisplay: Fusion.Value<{ DevMenuTypes.VehicleCatalogRowDisplay }> = scope:Value({})
	local liveDisplay: Fusion.Value<{ DevMenuTypes.VehicleLiveRowDisplay }> = scope:Value({})
	local berthDisplay: Fusion.Value<{ DevMenuTypes.VehicleBerthRowDisplay }> = scope:Value({})
	local registryText = scope:Value("Loading...")
	local rejectionText: Fusion.Value<string?> = scope:Value(nil :: string?)
	local loading = scope:Value(false)
	-- nil means "in front of me" -- see this file's header on why this one value is client-owned.
	local selectedBerth: Fusion.Value<string?> = scope:Value(nil :: string?)

	local refreshRequestedEvent = Instance.new("BindableEvent")
	local reloadRegistryRequestedEvent = Instance.new("BindableEvent")
	local spawnRequestedEvent = Instance.new("BindableEvent")
	local despawnRequestedEvent = Instance.new("BindableEvent")
	local despawnAllRequestedEvent = Instance.new("BindableEvent")

	local refreshButtonText = scope:Computed(function(use)
		return if use(loading) then "Loading..." else "Refresh"
	end)

	-- A berth that has been picked and then disappeared (a builder untagged the pad, or a refresh
	-- landed while the panel was open) must not leave the spawn pointed at a berth the server will
	-- reject. Computed rather than pushed, so the reconciliation happens wherever the list changes
	-- from rather than at each of the places that can change it.
	local effectiveBerth = scope:Computed(function(use)
		local wanted = use(selectedBerth)
		if wanted == nil then
			return nil :: string?
		end
		for _, berth in use(berthDisplay) do
			if berth.Name == wanted then
				return wanted
			end
		end
		return nil :: string?
	end)

	local spawnTargetText = scope:Computed(function(use)
		local berth = use(effectiveBerth)
		return if berth == nil then "Spawning in front of you" else `Spawning at berth "{berth}"`
	end)

	local catalogRows = scope:ForPairs(catalogDisplay, function(_use, innerScope, index, display)
		return display.Id,
			listRow(
				innerScope,
				display.NameText,
				display.DetailText,
				if display.AtCapacity then "Recycle" else "Spawn",
				10 + index,
				function()
					spawnRequestedEvent:Fire(display.Id, peek(effectiveBerth))
				end
			)
	end)

	local liveRows = scope:ForPairs(liveDisplay, function(_use, innerScope, index, display)
		return display.InstanceId,
			listRow(innerScope, display.NameText, display.DetailText, "Despawn", 10 + index, function()
				despawnRequestedEvent:Fire(display.InstanceId)
			end)
	end)

	-- The berth picker's "in front of me" entry is built here rather than injected into berthDisplay
	-- by the client module: it is not a berth, it is the ABSENCE of one, and putting it in the same
	-- list would mean every consumer of that list had to know which row was the fake.
	local berthButtons = scope:ForPairs(berthDisplay, function(_use, innerScope, index, display)
		return display.Name,
			Tab(innerScope, {
				Text = display.Label,
				Selected = innerScope:Computed(function(innerUse)
					return innerUse(effectiveBerth) == display.Name
				end),
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 10 + index,
				OnActivated = function()
					-- Pressing the selected berth again clears it, which is the only way back to "in
					-- front of me" without a second control that would otherwise exist purely to undo
					-- this one.
					if peek(effectiveBerth) == display.Name then
						selectedBerth:set(nil)
					else
						selectedBerth:set(display.Name)
					end
				end,
			})
	end)

	local emptyCatalogText = scope:Computed(function(use)
		if #use(catalogDisplay) > 0 then
			return ""
		end
		return "No vehicles in the registry. A vehicle is a folder under it whose name is the vehicle"
			.. " ID, containing the Model to clone."
	end)

	local emptyLiveText = scope:Computed(function(use)
		return if #use(liveDisplay) > 0 then "" else "Nothing spawned."
	end)

	local emptyBerthText = scope:Computed(function(use)
		if #use(berthDisplay) > 0 then
			return ""
		end
		return "No berths tagged. Tag a BasePart VehicleBerth to make it a named spawn pad."
	end)

	local children: { Instance } = {
		Section(scope, "Registry", 1, {
			noteLabel(scope, registryText, 1),
			noteLabel(
				scope,
				scope:Computed(function(use)
					return use(rejectionText) or ""
				end),
				2
			),
			scope:New "Frame" {
				Name = "RegistryActions",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = refreshButtonText,
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						Disabled = loading,
						OnActivated = function()
							refreshRequestedEvent:Fire()
						end,
					}),
					Button(scope, {
						Text = "Rescan",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						Disabled = loading,
						OnActivated = function()
							reloadRegistryRequestedEvent:Fire()
						end,
					}),
				},
			},
		}),

		Section(scope, "Spawn Target", 2, {
			noteLabel(scope, spawnTargetText, 1),
			noteLabel(scope, emptyBerthText, 2),
			berthButtons,
		}),

		Section(scope, "Catalog", 3, {
			noteLabel(scope, emptyCatalogText, 1),
			catalogRows,
		}),

		Section(scope, "Live", 4, {
			noteLabel(scope, emptyLiveText, 1),
			Button(scope, {
				Text = "Despawn All",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 2,
				Disabled = scope:Computed(function(use)
					return #use(liveDisplay) == 0
				end),
				OnActivated = function()
					despawnAllRequestedEvent:Fire()
				end,
			}),
			liveRows,
		}),
	}

	return {
		Children = children,
		CatalogDisplay = catalogDisplay,
		LiveDisplay = liveDisplay,
		BerthDisplay = berthDisplay,
		RegistryText = registryText,
		RejectionText = rejectionText,
		Loading = loading,
		RefreshRequested = refreshRequestedEvent.Event,
		ReloadRegistryRequested = reloadRegistryRequestedEvent.Event,
		SpawnRequested = spawnRequestedEvent.Event,
		DespawnRequested = despawnRequestedEvent.Event,
		DespawnAllRequested = despawnAllRequestedEvent.Event,
	}
end

return VehiclesTab
