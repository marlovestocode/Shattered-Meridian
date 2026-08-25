--!strict
--[[
	Announcement/init.lua

	Owns: the server-wide announcement banner -- top-center, auto-dismissing, driven entirely by
	Client/Announcement/AnnouncementClient.lua (the DevMenu_Announcement RemoteEvent's only listener).
	Unlike DevMenu/init.lua this is NOT whitelist-gated -- every player mounts and can see this, since
	an admin broadcast is meant for the whole server, not just other admins.

	Deliberately its own small Panel rather than reusing Components/PostureBreakBanner.lua's
	StatusBanner: that component's Title/Subtitle are both fixed-size, single-line, center-aligned
	text sized for short combat callouts ("POSTURE BROKEN" / "Enemy is exposed") -- an admin-authored
	message can run up to Constants.Debug.DevMenu.AnnouncementMaxLength (200) characters and needs to
	WRAP, which StatusBanner's fixed 300x64 frame has no room for. Follows the same "screen exposes a
	Value, driven from outside" pattern as that component, just with its own sized panel.

	IT NO LONGER SHARES StatusBanner's FADE, and that parted at Phase 5 of the HUD shell plan. This
	banner is a region tile and StatusBanner is not, so this one's entrance is the one every ambient
	tile wears (Components/Reveal.lua) rather than a hand-held Tokens.Motion.FadeSpring -- and it
	gained an arrival in the process, where before it only faded.

	Stacked below the combat outcome banner, so a mid-fight admin broadcast can never overlap it.
	That clearance has now been three different things and the last one is the one worth keeping: a
	152px constant baked into this banner's own Position, then a hardcoded 168px top inset on the
	TopCentre region (COMBAT_BANNER_BAND_BOTTOM, which went stale and was deleted), and now nothing
	at all -- the combat banner is a TopCentre tile at order 5 and this one is order 10, so the stack
	orders the two and no constant describes either.

	Does not own: when to show, for how long, or what text/color to display -- AnnouncementClient.lua
	owns all of that (reacting to the server-authoritative Announcement RemoteEvent); this module only
	draws whatever it's given.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)
local Reveal = require(script.Parent.Parent.Components.Reveal)

type Scope = Fusion.Scope<typeof(Fusion)>

export type AnnouncementDisplay = {
	Title: string,
	Message: string,
	Color: Color3,
}

export type AnnouncementHandle = {
	-- nil = nothing to show right now = hidden.
	Display: Fusion.Value<AnnouncementDisplay?>,
}

local ROOT_WIDTH = 420
local ROOT_HEIGHT = 108

-- Returns its handle AND its tile. The tile is unparented -- UI/init.lua hands it to
-- Shell/Regions.lua at TopCentre order 10, which owns where it sits and what it queues behind.
local function Announcement(scope: Scope): (AnnouncementHandle, Frame)
	local display: Fusion.Value<AnnouncementDisplay?> = scope:Value(nil :: AnnouncementDisplay?)

	local isVisible = scope:Computed(function(use)
		return use(display) ~= nil
	end)

	-- The fade is Components/Reveal.lua's now, and it comes with the arrival this banner never had:
	-- it used to spring transparency alone on Tokens.Motion.FadeSpring, so a broadcast materialised
	-- in place rather than settling in. Same shape as the other three ambient tiles as of Phase 5 of
	-- docs/architecture/2026-08-25-hud-shell-plan.md.
	--
	-- WHAT CHANGED BESIDES THE OWNER: FadeSpring is 14/0.7 and Reveal's is 22/1, so this banner now
	-- arrives slightly faster and, being critically damped, without the small transparency overshoot
	-- 0.7 gave it. That overshoot was never visible -- a transparency past 1 clamps -- which is
	-- exactly why nobody would have noticed it either way.
	local reveal = Reveal(scope, { Visible = isVisible })
	local contentTransparency = reveal.Transparency

	local accentColor = scope:Computed(function(use)
		local current = use(display)
		return if current then current.Color else Tokens.Color.AccentPrimary
	end)

	local titleText = scope:Computed(function(use)
		local current = use(display)
		return if current then current.Title else ""
	end)
	local messageText = scope:Computed(function(use)
		local current = use(display)
		return if current then current.Message else ""
	end)

	local root = Panel(scope, {
		Name = "AnnouncementBanner",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		-- Reveal's guard rather than isVisible directly: the banner has to stay drawn through its
		-- exit or the fade out is a cut.
		Visible = reveal.Mounted,
		Elevated = true,
		CornerAccent = true,
		BorderColor3 = accentColor,
		BorderThickness = 1.5,
		BorderTransparency = contentTransparency,

		Children = {
			reveal.Scale,
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.S),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			-- The announcement's own headline -- a section title, not an inline row label
			-- (docs/design/intro-redesign-handoff.md Phase F's Subheading sweep), so CardTitle
			-- (serif) rather than BodyLarge.
			Label(scope, {
				Text = titleText,
				Scale = "CardTitle",
				Color = accentColor,
				TextTransparency = contentTransparency,
				Size = UDim2.new(1, 0, 0, 22),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = messageText,
				Scale = "Body",
				Color = Tokens.Color.TextPrimary,
				TextTransparency = contentTransparency,
				TextWrapped = true,
				Size = UDim2.new(1, 0, 0, ROOT_HEIGHT - 22 - Tokens.Space.S * 2 - Tokens.Space.XS),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 2,
			}),
		},
	})

	return {
		Display = display,
	}, root
end

return { Mount = Announcement }
