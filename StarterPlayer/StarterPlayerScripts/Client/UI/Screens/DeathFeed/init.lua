--!strict
--[[
	DeathFeed.lua

	Owns: the mount point for the death/respawn overlay and kill feed named in
	ui-ux-philosophy.md's "Death/respawn and kill feed" surface. Empty until CombatSystem/
	RewardSystem actually fire kill events -- see this framework's other Screens for why building
	the content now would be optimistic UI state rather than a real feature.

	Design note carried over from ui-ux-philosophy.md for whoever builds this out: these moments
	are high-visibility but must never read as a punishment screen
	(gameplay-philosophy.md's anti-pattern against punishing engagement).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

local DeathFeed = {}

function DeathFeed.Mount(scope: Scope, playerGui: PlayerGui): ScreenGui
	return scope:New "ScreenGui" {
		Name = "DeathFeed",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = scope:New "Frame" {
			Name = "KillFeedList",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -Tokens.Space.L, 0, Tokens.Space.L),
			Size = UDim2.fromOffset(320, 200),
			BackgroundTransparency = 1,

			[Children] = scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
		},
	} :: ScreenGui
end

return DeathFeed
