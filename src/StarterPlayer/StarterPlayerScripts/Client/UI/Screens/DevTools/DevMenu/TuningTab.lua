--!strict
--[[
	DevMenu/TuningTab.lua

	Owns: the Tuning tab -- the live flight-feel numbers (Server/DevMenu/FlightTuning.lua), every field
	at once as a real NumericField over its real range, with its file default and a reset beside it.

	REPLACES A ONE-FIELD CYCLER. The old tab showed a single field at a time behind < and > arrows,
	nudged by +-1%/+-10% buttons, with no way to see the range, the default, or any other field while
	tuning one -- and flight feel is exactly the kind of thing tuned as a set (cruise speed against
	acceleration against bank angle). The server now lists each field's bounds and default, so the
	slider can span the real range.

	FIELDS DO NOT REBUILD WHEN THEIR VALUE CHANGES. The pairs are field name -> position; each
	NumericField reads its value through a Computed. A slider being dragged is never torn down by the
	server's answer to its own drag.

	The driver throttles what the sliders send (a drag commits ~20 times a second; the server's
	action bucket allows 4) -- see DevMenuClient's flight handling.

	Does not own: the numbers (the server's), or persisting them -- nothing does. A tuned value lives
	until the server restarts; the prose says to copy a keeper into FlightConstants.lua by hand.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local NumericFieldModule = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)

local DevMenuTypes = require(script.Parent.Types)
local Kit = require(script.Parent.Kit)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Intent = DevMenuTypes.Intent
type FieldInfo = Types.FlightTuningInfo

export type TuningTabProps = {
	Visible: UsedAs<boolean>,
	Flight: UsedAs<{ FieldInfo }>,
	Fire: (Intent) -> (),
}

local RESET_WIDTH = 72

-- Step sizes and precision from the field's range: a 0..5 multiplier wants hundredths, a 5..300 speed
-- wants whole numbers.
local function stepsFor(range: number): ({ number }, number)
	if range <= 5 then
		return { 0.01, 0.1 }, 2
	elseif range <= 100 then
		return { 0.1, 1 }, 1
	end
	return { 1, 10 }, 0
end

local function formatDefault(value: number, decimals: number): string
	return string.format(`%.{decimals}f`, value)
end

local function TuningTab(scope: Scope, props: TuningTabProps): ScrollingFrame
	local byField = scope:Computed(function(use)
		local map: { [string]: FieldInfo } = {}
		for _, info in use(props.Flight) do
			map[info.Field] = info
		end
		return map
	end)
	local order = scope:Computed(function(use)
		local positions: { [string]: number } = {}
		for index, info in use(props.Flight) do
			positions[info.Field] = index
		end
		return positions
	end)
	local isLoading = scope:Computed(function(use)
		return #use(props.Flight) == 0
	end)

	local fields = scope:ForPairs(order, function(_use, innerScope: Scope, field: string, index: number)
		-- Bounds and default are fixed for a field's lifetime, so they are read once here -- straight off
		-- the source list (a Value, so always current) rather than byField, which may not have
		-- recomputed yet at the moment this runs.
		local initial: FieldInfo? = nil
		for _, info in Fusion.peek(props.Flight) do
			if info.Field == field then
				initial = info
			end
		end
		assert(initial, `TuningTab: {field} is in the order but not the list`)
		local steps, decimals = stepsFor(initial.Max - initial.Min)
		return field,
			Stack.Row(innerScope, {
				Name = field,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Gap = Tokens.Space.M,
				AlignY = Enum.VerticalAlignment.Top,
				LayoutOrder = index,
				Children = {
					Stack.Fill(
						innerScope,
						NumericFieldModule.Mount(innerScope, {
							Label = initial.DisplayName,
							Value = innerScope:Computed(function(use)
								local info = use(byField)[field]
								return if info then info.Value else initial.Default
							end),
							Min = initial.Min,
							Max = initial.Max,
							Steps = steps,
							Decimals = decimals,
							Hint = `File default {formatDefault(initial.Default, decimals)} · range {initial.Min} to {initial.Max}`,
							OnChanged = function(value: number)
								props.Fire({ Kind = "FlightSet", Field = field, Value = value })
							end,
						})
					),
					Kit.Button(innerScope, {
						Text = "Reset",
						Order = 2,
						Size = UDim2.fromOffset(RESET_WIDTH, Kit.ButtonHeight),
						Disabled = innerScope:Computed(function(use)
							local info = use(byField)[field]
							return info == nil or info.Value == info.Default
						end),
						OnActivated = function()
							props.Fire({ Kind = "FlightReset", Field = field })
						end,
					}),
				},
			})
	end)

	local children: { Instance } = {
		Kit.Heading(scope, "FLIGHT FEEL", 1),
		Kit.Prose(
			scope,
			"Live for everyone flying in this server, from the next frame. In memory only: a restart puts every field back, so copy a value you want to keep into FlightConstants.lua.",
			2
		),
		Kit.Prose(scope, "Loading the flight fields...", 3, isLoading),
		Stack.New(scope, {
			Name = "Fields",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.L,
			LayoutOrder = 4,
			Children = { fields :: any },
		}),
		Kit.Armed(scope, {
			Idle = "Reset every field",
			Armed = "Reset all? Again",
			Order = 5,
			Visible = scope:Computed(function(use)
				return not use(isLoading)
			end),
			OnConfirm = function()
				props.Fire({ Kind = "FlightResetAll" })
			end,
		}),
	}

	return Kit.Page(scope, "TuningTab", props.Visible, children)
end

return TuningTab
