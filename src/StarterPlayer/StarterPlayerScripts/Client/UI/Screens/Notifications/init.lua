--!strict
--[[
	Notifications/init.lua

	Owns: the one tile that draws whichever notification is currently up -- its size, its three lines,
	and the accent it wears.

	Does NOT own: the queue, the ordering, how long anything stays, or which kinds exist. All of that
	is Shell/Notify.lua, and this file reads exactly one value off its handle. See that module's
	header for why the two are separate files rather than the one plan 3.5 specced (Shell/ may not
	require Components/, and Components/ModalScreen already requires Shell/).

	A TopCentre tile at order 20, behind the announcement banner at order 10. That ordering is the
	channel's answer to "an admin broadcast and a rank-up in the same second": the broadcast is nearer
	the top of the screen and the notification queues below it, rather than the two racing for one
	strip the way the kill feed and the fuel gauge used to race for the top-right corner.

	ONE TILE, NOT A COLUMN. Shell/Notify.lua's header has the argument; the short version is that
	three toasts at once over live combat is the opposite of docs/ui-ux-philosophy.md's HUD rule.

	THE EYEBROW IS THE KIND, IN WORDS. Colour is never the only signal in this UI -- the accent says
	which kind at a glance and the eyebrow says it in text for a player who cannot use the accent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)
local Inset = require(script.Parent.Parent.Components.Inset)
local Reveal = require(script.Parent.Parent.Components.Reveal)
local Notify = require(script.Parent.Parent.Shell.Notify)

type Scope = Fusion.Scope<typeof(Fusion)>

-- Wide enough for a tier name and its reading on one line each, and no wider: this sits over live
-- gameplay in the centre of the screen, where every pixel of width is in the player's way.
local TILE_WIDTH = 340
-- Fixed rather than AutomaticSize, unlike every ambient corner tile. Those grow because their
-- content genuinely varies; this one has exactly three lines whether or not the middle one is
-- filled, and a tile that changed height between notifications would make the announcement banner
-- above it jump.
local TILE_HEIGHT = 68

local EYEBROW_HEIGHT = 12
local TITLE_HEIGHT = 22
local DETAIL_HEIGHT = 14

-- Returns the tile. Unparented -- UI/init.lua hands it to Shell/Regions.lua's TopCentre at order 20,
-- and this file does not know which corner that is.
local function Notifications(scope: Scope, notify: Notify.NotifyHandle): Frame
	local current = notify.Current

	local visible = scope:Computed(function(use): boolean
		return use(current) ~= nil
	end)
	-- The same entrance every region tile wears (Components/Reveal.lua). A notification is the one
	-- surface here that is ALWAYS a transition -- it exists for a few seconds and then does not --
	-- so the exit guard is not a nicety: without it every notification would end in a cut.
	local reveal = Reveal(scope, { Visible = visible })

	local accent = scope:Computed(function(use): Color3
		local notification = use(current)
		return if notification then Notify.Style(notification.Kind).Accent else Tokens.Color.AccentPrimary
	end)

	return Panel(scope, {
		Name = "NotificationTile",
		Size = UDim2.fromOffset(TILE_WIDTH, TILE_HEIGHT),
		Visible = reveal.Mounted,
		Elevated = true,
		CornerAccent = true,
		BorderColor3 = accent,
		BorderThickness = 1.5,
		BorderTransparency = reveal.Transparency,

		Children = {
			reveal.Scale,
			Inset(scope, { X = Tokens.Space.M, Y = Tokens.Space.S }),
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = scope:Computed(function(use): string
					local notification = use(current)
					return if notification then Notify.Style(notification.Kind).Eyebrow else ""
				end),
				Scale = "Detail",
				Color = accent,
				TextTransparency = reveal.Transparency,
				Size = UDim2.new(1, 0, 0, EYEBROW_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = scope:Computed(function(use): string
					local notification = use(current)
					return if notification then notification.Title else ""
				end),
				Scale = "CardTitle",
				Color = Tokens.Color.TextPrimary,
				TextTransparency = reveal.Transparency,
				Size = UDim2.new(1, 0, 0, TITLE_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 2,
			}),
			Label(scope, {
				Text = scope:Computed(function(use): string
					local notification = use(current)
					return if notification and notification.Detail then notification.Detail else ""
				end),
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				TextTransparency = reveal.Transparency,
				-- Taken out of the layout entirely when there is no detail, rather than left as a
				-- blank line. The tile height is fixed and the list is centred, so an empty third row
				-- would push the title visibly off centre for a notification with nothing to say.
				Visible = scope:Computed(function(use): boolean
					local notification = use(current)
					return notification ~= nil and notification.Detail ~= nil
				end),
				Size = UDim2.new(1, 0, 0, DETAIL_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 3,
			}),
		},
	}) :: Frame
end

return { Mount = Notifications }
