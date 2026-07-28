--!strict
--[[
	Section.lua

	Owns: a full-width, auto-height grouping panel for related controls within a screen -- Panel.lua
	reused as a plain sub-section container with a title above its children (e.g. DevMenu's
	"Training Dummy"/"Health"/"Bug Reports" groupings). Promoted out of Screens/DevMenu/init.lua
	during that screen's Sidebar/ContentArea split (see that module's own header) once a SECOND
	consumer (Sidebar.lua's roster section, alongside ContentArea.lua's Spawn/Admin/Tuning/Reports
	sections) needed the exact same shape -- the same "duplicated in two places, centralized once a
	second caller needs it" precedent Geometry.lua's own header documents for CORNERS.

	The title renders through Components/TrackedLabel.lua, tracked caps and upper-cased automatically
	("tracked caps on tab and section headers", docs/design/intro-redesign-handoff.md Phase F) --
	safe here specifically because `title` is already a plain `string` parameter, never a reactive
	UsedAs<string>, so every call site is guaranteed static (unlike Tab.lua's own TrackedCaps, which
	stays opt-in because several of ITS call sites pass genuinely live text -- see that file's header).

	`children`'s element type is `any`, not `Instance` -- a caller may splice in a
	scope:ForPairs(...)/scope:ForValues(...) result (a Fusion state-collection object, not a plain
	Instance) alongside ordinary Instances, the same way Children.luau itself accepts either at any
	nesting depth (see that module's processChild).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)
local TrackedLabel = require(script.Parent.TrackedLabel)

type Scope = Fusion.Scope<typeof(Fusion)>

local function Section(scope: Scope, title: string, layoutOrder: number, children: { any }): Frame
	return Panel(scope, {
		Name = title,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.M),
				PaddingBottom = UDim.new(0, Tokens.Space.M),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			TrackedLabel(scope, {
				Text = string.upper(title),
				Scale = "Action",
				LayoutOrder = 1,
			}),
			table.unpack(children),
		},
	}) :: Frame
end

return Section
