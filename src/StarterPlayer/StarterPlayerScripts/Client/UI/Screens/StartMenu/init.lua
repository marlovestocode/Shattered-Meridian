--!strict
--[[
	StartMenu/init.lua

	Owns: the title screen shown before anything else in the client (Client/StartMenu/
	StartMenuClient.lua owns WHEN -- this module only renders whatever it's given). Title, tagline,
	Divider.Flourish (same centrepiece motif as RaceSelect.lua's own header, for visual continuity
	across every boot-time screen), and a single Play button.

	The Play button stays Variant = "Primary" with STATIC text ("PLAY") rather than switching to
	"JOINING..." on click -- Components/Button.lua's own header documents that a Variant'd button
	renders its Text through TrackedLabel.lua, which reads Text ONCE via peek at construction, never
	reactively, and explicitly frames extending that as a deliberate choice for a future caller to
	make, not a default. Rather than extend Button.lua for this one screen, the "joining/failed"
	state shows via a separate status line below the button instead (reactive), while the button
	itself only reacts via its existing (already-reactive) Disabled prop.

	DisplayOrder = 30 -- above Screens/Loading/init.lua's own 20 and Screens/Onboarding/init.lua's 10,
	continuing the same headroom-for-future-overlap reasoning Loading's own comment already states.
	All three stay temporally exclusive in practice: StartMenuClient.Run() either returns immediately
	(this arrival was via a Play teleport) before this screen would ever mount, or this screen's scope
	is the only one alive on this server, forever, since there is no legitimate path from here into
	Loading/Onboarding on the SAME server -- see StartMenuClient.lua's own header.

	Does not own: the teleport request, retry logic, or the FromStartMenu arrival check
	(StartMenuClient.lua owns all three).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Components.Label)
local Divider = require(script.Parent.Parent.Components.Divider)
local Button = require(script.Parent.Parent.Components.Button)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type StartMenuProps = {
	IsRequesting: Fusion.Value<boolean>,
	ErrorText: Fusion.Value<string>,
	OnPlayRequested: () -> (),
}

local DISPLAY_ORDER = 30
local COLUMN_WIDTH = 360
local TITLE_TEXT = "SHATTERED MERIDIAN"
local TAGLINE_TEXT = "A world reshaped by the Shattering."
local JOINING_TEXT = "Joining a new server..."

local function StartMenu(scope: Scope, playerGui: PlayerGui, props: StartMenuProps): ScreenGui
	-- One status line covers both states this screen ever shows below the button -- "joining" while
	-- a request is in flight (takes priority: IsRequesting only goes true right before firing the
	-- request, so there's nothing stale from a PRIOR failed attempt left to show), otherwise
	-- whatever ErrorText currently holds ("" -- meaning nothing, the idle case -- until a request
	-- actually fails).
	local statusText = scope:Computed(function(use)
		if use(props.IsRequesting) then
			return JOINING_TEXT
		end
		return use(props.ErrorText)
	end)
	local statusColor = scope:Computed(function(use)
		return if use(props.IsRequesting) then Tokens.Color.TextSecondary else Tokens.Color.Danger
	end)
	-- TextTransparency, not a Visible prop -- Label.lua has no Visible prop in its current prop list.
	local statusTransparency = scope:Computed(function(use)
		return if use(statusText) == "" then 1 else 0
	end)

	local root = scope:New "Frame" {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Tokens.Color.Background,
		BorderSizePixel = 0,

		[Children] = {
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
					Label(scope, {
						Text = TAGLINE_TEXT,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 16),
						LayoutOrder = 2,
					}),
					Divider.Flourish(scope, {
						Size = UDim2.fromOffset(160, 6),
						LayoutOrder = 3,
					}),
					Button(scope, {
						Text = "PLAY",
						Variant = "Primary",
						Size = UDim2.fromOffset(200, Tokens.Control.RowHeight),
						Disabled = props.IsRequesting,
						LayoutOrder = 4,
						OnActivated = props.OnPlayRequested,
					}),
					Label(scope, {
						Text = statusText,
						Scale = "Detail",
						Color = statusColor,
						TextXAlignment = Enum.TextXAlignment.Center,
						TextTransparency = statusTransparency,
						Size = UDim2.new(1, 0, 0, 16),
						LayoutOrder = 5,
					}),
				},
			},
		},
	} :: Frame

	return scope:New "ScreenGui" {
		Name = "StartMenu",
		ResetOnSpawn = false,
		Enabled = true,
		DisplayOrder = DISPLAY_ORDER,
		-- True full-bleed, matching HUD/init.lua's and CombatFeedback/init.lua's own use of this same
		-- property -- without it, Roblox insets GUI content by the top bar's height by default, which
		-- would leave a gap of whatever's behind this screen visible along the top edge of what's
		-- meant to be an edge-to-edge title screen.
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = root,
	} :: ScreenGui
end

return { Mount = StartMenu }
