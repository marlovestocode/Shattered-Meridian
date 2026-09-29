--!strict
--[[
	MoveEditor/TestBench.lua

	Owns: the readout's TEST BENCH -- what a Test swing is thrown AT: the Dev Menu's training dummy (and
	whether it holds its guard), a sparring bot by style and difficulty, a way to clear them all, and the
	server-wide hitbox visualiser.

	EVERY CONTROL IS A DEV MENU REMOTE the driver already has (Constants.Debug.DevMenu.RemoteNames) --
	this block adds no server code. The bot choices come from TrainingBotConstants' own presentation
	order (StyleOrder / DifficultyOrder), never a list typed here, so a style added there appears here.

	THE DUMMY CANNOT PARRY. It guards (DebugDummySystem.SetGuard) and nothing else, so "does this move get
	parried" is answered by a ParryOnly bot. The caption says so, because the obvious guess -- that a
	guarding dummy also parries -- is wrong.

	Does not own: what any control does (the On* props -- the driver's) or the bench's state (the handle's
	Values, which the driver seeds from the server).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local TrainingBotConstants = require(ReplicatedStorage.Shared.TrainingBot.TrainingBotConstants)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local DropdownModule = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local SectionHeading = require(script.Parent.Parent.Parent.Parent.Components.SectionHeading)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type TestBenchProps = {
	LayoutOrder: number,
	Visible: UsedAs<boolean>,
	DummyGuard: UsedAs<boolean>,
	BotStyle: Fusion.Value<string>,
	BotDifficulty: Fusion.Value<string>,
	VolumesVisible: UsedAs<boolean>,
	OnSpawnDummy: () -> (),
	OnDummyGuard: (enabled: boolean) -> (),
	OnSpawnBot: () -> (),
	OnClearBench: () -> (),
	OnToggleVolumes: (visible: boolean) -> (),
}

local BUTTON_HEIGHT = Tokens.Control.StepButtonSize

local function options(order: { string }): { DropdownModule.DropdownOption }
	local result: { DropdownModule.DropdownOption } = {}
	for _, name in order do
		table.insert(result, { Value = name, Text = name })
	end
	return result
end

local function halfButton(scope: Scope, text: string, order: number, onActivated: () -> ()): Instance
	return Button(scope, {
		Text = text,
		Variant = "Secondary",
		Size = UDim2.new(0.5, -Tokens.Space.S / 2, 0, BUTTON_HEIGHT),
		LayoutOrder = order,
		OnActivated = onActivated,
	})
end

local function holder(scope: Scope, name: string, order: number, child: Instance): Frame
	return scope:New "Frame" {
		Name = name,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		[Fusion.Children] = child,
	} :: Frame
end

local function TestBench(scope: Scope, props: TestBenchProps): Frame
	return Stack.New(scope, {
		Name = "TestBench",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.M,
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		Children = {
			SectionHeading(scope, { Text = "TEST BENCH", LayoutOrder = 10 }),
			Label(scope, {
				Text = "The dummy guards but never parries. To test against a parry, spawn a ParryOnly bot.",
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.fromScale(1, 0),
				AutoHeight = true,
				TextWrapped = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 20,
			}),
			Stack.Row(scope, {
				Name = "Dummy",
				Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
				Gap = Tokens.Space.S,
				LayoutOrder = 30,
				Children = {
					halfButton(scope, "Spawn dummy", 1, props.OnSpawnDummy),
					halfButton(scope, "Clear all", 2, props.OnClearBench),
				},
			}),
			holder(
				scope,
				"DummyGuard",
				40,
				Toggle(scope, {
					Label = "Dummies hold their guard",
					Value = props.DummyGuard,
					OnChanged = props.OnDummyGuard,
				})
			),
			holder(
				scope,
				"BotStyle",
				50,
				DropdownModule.Mount(scope, {
					Label = "Bot style",
					Options = options(TrainingBotConstants.StyleOrder),
					Value = props.BotStyle,
					OnChanged = function(value: string)
						props.BotStyle:set(value)
					end,
				})
			),
			holder(
				scope,
				"BotDifficulty",
				60,
				DropdownModule.Mount(scope, {
					Label = "Bot difficulty",
					Options = options(TrainingBotConstants.DifficultyOrder),
					Value = props.BotDifficulty,
					OnChanged = function(value: string)
						props.BotDifficulty:set(value)
					end,
				})
			),
			Button(scope, {
				Text = "Spawn sparring bot",
				Variant = "Secondary",
				Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
				LayoutOrder = 70,
				OnActivated = props.OnSpawnBot,
			}),
			holder(
				scope,
				"Volumes",
				80,
				Toggle(scope, {
					Label = "Show live hitbox volumes",
					Hint = "Server-wide: every swing draws its real volume for everyone. Turn it off when done.",
					Value = props.VolumesVisible,
					OnChanged = props.OnToggleVolumes,
				})
			),
		},
	})
end

return TestBench
