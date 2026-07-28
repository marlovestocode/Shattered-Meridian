--!strict
--[[
	Loading/init.lua

	Owns: the boot-time loading screen -- shown while Client/Loading/AssetPreloader.lua's preload
	pass runs, torn down once it completes. A single, self-contained screen (unlike
	Screens/Onboarding/init.lua, there's no multi-stage switching here), so it owns its own fade-out
	directly off the Complete prop rather than needing a separate stage-switching root.

	Follows the same "screen exposes state, driven from outside" convention as every other screen in
	this folder -- Client/Loading/LoadingClient.lua owns writing Progress/Total (from
	AssetPreloader.Run's onProgress callback) and flipping Complete once that call returns; this
	module only renders whatever it's given.

	DisplayOrder = 20 -- above Screens/Onboarding/init.lua's own ScreenGui (DisplayOrder = 10) and
	below Screens/StartMenu/init.lua's own (DisplayOrder = 30, the true first thing shown) --
	headroom for any future transition overlap between any of the three, even though today they're
	all temporally exclusive: StartMenuClient.Run() returns (or the engine kills the whole script)
	before LoadingClient.Run() ever starts, and LoadingClient.Run() tears its own scope down before
	OnboardingClient.Run() -- and therefore Onboarding's own scope -- is ever created.

	Does not own: what counts as "loaded" or when Complete flips (AssetPreloader.lua/
	LoadingClient.lua own both).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Components.Label)
local Divider = require(script.Parent.Parent.Components.Divider)
local Bar = require(script.Parent.Parent.Components.Bar)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type LoadingProps = {
	Progress: Fusion.Value<number>,
	Total: Fusion.Value<number>,
	Complete: Fusion.Value<boolean>,
}

local DISPLAY_ORDER = 20
local COLUMN_WIDTH = 360
local TITLE_TEXT = "SHATTERED MERIDIAN"
local STATUS_TEXT = "Loading..."

local function Loading(scope: Scope, playerGui: PlayerGui, props: LoadingProps): ScreenGui
	-- Springs 0 (fully opaque) -> 1 (fully hidden) the instant Complete flips true -- the same
	-- one-shot fade-in-reverse idiom Screens/Onboarding/init.lua's own slideUpSettled uses, minus the
	-- position slide (a plain fade reads correctly for a screen that's about to disappear entirely,
	-- not hand off to another stage).
	local groupTransparency = scope:Spring(
		scope:Computed(function(use)
			return if use(props.Complete) then 1 else 0
		end),
		Tokens.Motion.FadeSpring.Speed,
		Tokens.Motion.FadeSpring.Damping
	)

	local root = scope:New "CanvasGroup" {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		GroupTransparency = groupTransparency,

		[Children] = {
			scope:New "Frame" {
				Name = "Backdrop",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Tokens.Color.Background,
				BorderSizePixel = 0,
			},
			scope:New "Frame" {
				Name = "Column",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(COLUMN_WIDTH, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.M),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Label(scope, {
						Text = TITLE_TEXT,
						Scale = "Title",
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 36),
						LayoutOrder = 1,
					}),
					Divider.Flourish(scope, {
						Size = UDim2.fromOffset(160, 6),
						LayoutOrder = 2,
					}),
					Bar(scope, {
						Value = props.Progress,
						Max = props.Total,
						Size = UDim2.new(1, 0, 0, 4),
						FillColor = Tokens.Color.AccentPrimary,
						Glow = true,
						LayoutOrder = 3,
					}),
					Label(scope, {
						Text = STATUS_TEXT,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 16),
						LayoutOrder = 4,
					}),
				},
			},
		},
	} :: CanvasGroup

	return scope:New "ScreenGui" {
		Name = "Loading",
		ResetOnSpawn = false,
		Enabled = true,
		DisplayOrder = DISPLAY_ORDER,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = root,
	} :: ScreenGui
end

return { Mount = Loading }
