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
	Value, driven from outside" pattern and the same one-shot Spring fade-in feel (Tokens.Motion.
	FadeSpring) as that component, just with its own sized panel.

	Stacked below CombatFeedback's PostureBreak (YOffset 0) and Disarmed (YOffset 72) banners -- see
	ANNOUNCEMENT_Y_OFFSET below -- so a mid-fight admin broadcast can never overlap either.

	Does not own: when to show, for how long, or what text/color to display -- AnnouncementClient.lua
	owns all of that (reacting to the server-authoritative Announcement RemoteEvent); this module only
	draws whatever it's given.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)

local Children = Fusion.Children

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
-- Below CombatFeedback's PostureBreak (YOffset 0, per StatusBanner's own default) and Disarmed
-- (YOffset 72) banners -- see this file's own header.
local ANNOUNCEMENT_Y_OFFSET = 152

local FADE_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local FADE_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

local function Announcement(scope: Scope, playerGui: PlayerGui): AnnouncementHandle
	local display: Fusion.Value<AnnouncementDisplay?> = scope:Value(nil :: AnnouncementDisplay?)

	local isVisible = scope:Computed(function(use)
		return use(display) ~= nil
	end)

	-- Same one-shot decorative fade-in as Components/PostureBreakBanner.lua's StatusBanner -- 0 while
	-- hidden, springs to 1 the moment a display arrives, so the banner settles in instead of snapping.
	local fadeIn = scope:Spring(
		scope:Computed(function(use)
			return if use(isVisible) then 1 else 0
		end),
		FADE_SPRING_SPEED,
		FADE_SPRING_DAMPING
	)
	local contentTransparency = scope:Computed(function(use)
		return 1 - use(fadeIn)
	end)

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
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, Tokens.Space.XXL + ANNOUNCEMENT_Y_OFFSET),
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		Visible = isVisible,
		Elevated = true,
		CornerAccent = true,
		BorderColor3 = accentColor,
		BorderThickness = 1.5,
		BorderTransparency = contentTransparency,

		Children = {
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

	scope:New "ScreenGui" {
		Name = "Announcement",
		ResetOnSpawn = false,
		Enabled = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = root,
	}

	return {
		Display = display,
	}
end

return { Mount = Announcement }
