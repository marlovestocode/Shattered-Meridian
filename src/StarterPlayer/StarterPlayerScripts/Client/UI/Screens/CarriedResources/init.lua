--!strict
--[[
	CarriedResources/init.lua

	Owns: the small corner readout of a player's own carried coal/water (Types.PlayerProfile.blimpFuel)
	-- the "so I can see what I have" surface the Blimp Fuel System was missing: gathering had no
	-- visible feedback at all before this, and a player had no way to check their stock short of
	-- walking up to a blimp's furnace and depositing blind. Client/Blimp/BlimpController.lua is the
	-- integration module that drives this screen's handle (SetCarried on every CarriedFuelUpdated
	-- push) -- this file itself sends and receives nothing, the same "screen exposes state, client
	-- module drives it" split Screens/BlimpFuel/init.lua's own header follows.

	VISIBLE ONLY WHILE CARRYING SOMETHING. The overwhelming majority of players never touch this
	feature in a given session, and a permanent "Coal: 0  Water: 0" tile would be dead weight on every
	one of their screens forever. It appears the moment either count leaves zero and disappears the
	moment both return to it (spending the last of one down to 0 while still carrying the other keeps
	it up, showing the resource that's actually left) -- never on a timer, never dismissable, because
	there is nothing to interact with here, only a fact to check.

	NOT REACTIVE TO A BLIMP'S OWN TANK. This has no relationship to Screens/BlimpFuel/init.lua's
	Coal/Water gauges -- those show what's IN A TANK, gated on piloting a fuel-gated blimp; this shows
	what's IN YOUR OWN POCKET, visible to anyone regardless of whether they've ever been near a blimp.
	Depositing moves a number from one screen to the other; neither screen knows the other exists.

	Does not own: the gather/deposit logic that changes these numbers (Server/Systems/
	ResourceGatheringSystem.lua, Server/Systems/BlimpSystem.depositFuel), or when to call SetCarried
	(Client/Blimp/BlimpController.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type CarriedResourcesHandle = {
	SetCarried: (coal: number, water: number) -> (),
}

local CarriedResources = {}

local PANEL_WIDTH = 160

local function resourceRow(scope: Scope, layoutOrder: number, caption: string, value: Fusion.Value<number>): Frame
	local valueText = scope:Computed(function(use)
		return tostring(math.floor(use(value)))
	end)

	return scope:New "Frame" {
		Name = `Row_{caption}`,
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + 2),
		BackgroundTransparency = 1,

		[Children] = {
			Label(scope, {
				Text = caption,
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromScale(0, 0),
				Size = UDim2.fromScale(0.5, 1),
			}),
			Label(scope, {
				Text = valueText,
				Scale = "Numeral",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.fromScale(0.5, 1),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
		},
	} :: Frame
end

-- Returns its handle AND its tile. The tile is unparented -- UI/init.lua hands it to
-- Shell/Regions.lua, which owns which corner it lands in and what it stacks with. See that module's
-- header; this screen deliberately no longer knows either.
function CarriedResources.Mount(scope: Scope): (CarriedResourcesHandle, Frame)
	local coal = scope:Value(0)
	local water = scope:Value(0)

	local visible = scope:Computed(function(use)
		return use(coal) > 0 or use(water) > 0
	end)

	local function setCarried(newCoal: number, newWater: number): ()
		coal:set(newCoal)
		water:set(newWater)
	end

	local tile = Panel(scope, {
		Name = "CarriedResourcesPanel",
		Size = UDim2.fromOffset(PANEL_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = visible,
		Elevated = true,
		CornerAccent = true,

		Children = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
				PaddingTop = UDim.new(0, Tokens.Space.S),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = "CARRIED",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 1,
			}),
			resourceRow(scope, 2, "Coal", coal),
			resourceRow(scope, 3, "Water", water),
		},
	})

	return {
		SetCarried = setCarried,
	}, tile
end

return CarriedResources
