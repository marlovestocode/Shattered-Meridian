--!strict
--[[
	Section.lua

	Owns: a full-width, auto-height grouping panel for related controls within a screen -- Panel.lua
	reused as a plain sub-section container with a title above its children (e.g. DevMenu's
	"Training Dummy"/"Health"/"Bug Reports" groupings). Promoted out of Screens/DevTools/DevMenu/init.lua
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

	`description` (optional, additive): a wrapped, TextSecondary subtitle rendered directly under the
	title at LayoutOrder 2 -- the docs-site "explain what this group of controls does" convention the
	Move Editor's redesigned PropertyEditor.lua wants for every one of its 11 sections. `nil` (the
	default for every pre-existing call site) renders nothing at that LayoutOrder, so no existing
	caller's output changes. A caller that DOES pass a description must start its own `children`'s
	LayoutOrder at 3, not 2, to avoid colliding with this slot. No longer capped at one line: it uses
	Label.lua's AutoHeight mode, so a two- or four-sentence description simply makes the card taller
	rather than clipping (see that Label's own comment below).

	`icon` (optional, additive): a pre-built glyph Instance (Components/SectionIcon.lua's own output,
	for every current caller) rendered immediately left of the title instead of above/below it --
	turns the title row into a small horizontal UIListLayout only when an icon is actually given, so
	every caller that omits it (still every DevMenu caller) keeps the original bare-TrackedLabel
	rendering byte-for-byte.

	`summary` (optional, additive): a right-aligned, live one-line readout on the title row -- what
	this section's own fields currently add up to, stated back to the author without making them
	open a different section to find out (the Move Editor's Timing card reads "0.65s total, 0.60s
	cooldown" while they drag its steppers). Renders nothing when omitted, which is still every
	caller but that one.

	Unlike `title`, `summary` is deliberately a UsedAs<string>, and the difference is load-bearing.
	`title` is constrained to a plain static string precisely because TrackedLabel.lua peeks its text
	once at build time (see this file's own note above); a summary is a DERIVED value that must
	change as the author edits, so it is rendered by Label.lua instead, which binds reactively.
	A caller building one with scope:Computed must therefore `use()` the draft inside that closure,
	never `peek()` it -- a peek reads without subscribing and would freeze the readout at whatever it
	said the first time it rendered.

	`emphasis` (optional, additive, defaults to off): swaps this card's border from Tokens.Border.
	Standard (18%) to Tokens.Border.Lit (32%) and its fill from Surface to SurfaceElevated --
	docs/ui-ux-philosophy.md's own Borders rule ("higher importance: brighter edge highlight, more
	contrast"). Opt-in rather than a global default change so existing DevMenu callers -- a lower-
	stakes admin tool, not a "detailed menu" screen per that doc's own Menu Design section -- are
	unaffected; the Move Editor's own PropertyEditor.lua passes this for all 9 of its sections.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)
local TrackedLabel = require(script.Parent.TrackedLabel)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- Clears SectionIcon.lua's own 16px glyph box with room to spare for TrackedLabel's 11px Action
-- step. Only needed on the `summary` path, where the title row stops being an auto-height list and
-- becomes a fixed band with something anchored to each end.
local TITLE_ROW_HEIGHT = 20

local function Section(
	scope: Scope,
	title: string,
	layoutOrder: number,
	children: { any },
	description: string?,
	icon: Instance?,
	emphasis: boolean?,
	summary: UsedAs<string>?
): Frame
	local titleLabel = TrackedLabel(scope, {
		Text = string.upper(title),
		Scale = "Action",
		LayoutOrder = if icon then 2 else 1,
	})

	local titleRow: Instance
	if summary ~= nil then
		-- A fixed-height band with the icon+title group anchored left and the readout anchored right
		-- -- the same construction MoveList.lua's own "Moves" header and MoveEditor/init.lua's screen
		-- header already use, rather than a new idiom. It cannot be the auto-height horizontal
		-- UIListLayout the icon-only branch below uses, because a UIListLayout has no way to push one
		-- child to the far end of the row.
		local titleGroup: { Instance } = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
		}
		if icon then
			table.insert(titleGroup, icon :: Instance)
		end
		table.insert(titleGroup, titleLabel)

		titleRow = scope:New "Frame" {
			Name = "TitleRow",
			Size = UDim2.new(1, 0, 0, TITLE_ROW_HEIGHT),
			BackgroundTransparency = 1,
			LayoutOrder = 1,

			[Children] = {
				scope:New "Frame" {
					Name = "TitleGroup",
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
					Size = UDim2.fromOffset(0, TITLE_ROW_HEIGHT),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundTransparency = 1,

					[Children] = titleGroup,
				},
				Label(scope, {
					Text = summary :: UsedAs<string>,
					Scale = "Detail",
					Color = Tokens.Color.TextSecondary,
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.fromScale(1, 0.5),
					-- Half the row: enough for a real summary, and a hard stop that keeps a long one
					-- from sliding underneath the title anchored at the other end.
					Size = UDim2.fromScale(0.5, 1),
					TextXAlignment = Enum.TextXAlignment.Right,
				}),
			},
		}
	elseif icon then
		titleRow = scope:New "Frame" {
			Name = "TitleRow",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 1,

			[Children] = {
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Tokens.Space.S),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				icon :: Instance,
				titleLabel,
			},
		}
	else
		titleRow = titleLabel
	end

	local headerChildren: { Instance } = { titleRow }
	if description then
		table.insert(
			headerChildren,
			Label(scope, {
				-- AutoHeight, not a hand-counted pixel height: this used to be a fixed 32px on the
				-- reasoning that two wrapped Detail lines was enough for "every one-sentence
				-- description this component is meant for," which held right up until the Move
				-- Editor's Copy.lua started writing descriptions worth reading. Label.lua gained a
				-- real fixed-width/auto-height mode for exactly this (see its own header); the
				-- description now takes whatever height its text needs, and this Panel is already
				-- AutomaticSize.Y so the card grows with it.
				Text = description,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				Size = UDim2.fromScale(1, 0),
				LayoutOrder = 2,
			})
		)
	end

	local borderTint = if emphasis then Tokens.Border.Lit else Tokens.Border.Standard

	return Panel(scope, {
		Name = title,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,
		Elevated = emphasis,
		BorderColor3 = borderTint.Color,
		BorderTransparency = borderTint.Transparency,

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
			table.unpack(headerChildren),
			table.unpack(children),
		},
	}) :: Frame
end

return Section
