--!strict
--[[
	MoveStatsGrid.lua

	Owns: the MOVE STATS block in the preview pane, from the Figma Make reference -- a 2-up grid of
	small cards (Damage, Knockback, Windup, Active, Recovery, Cooldown), each carrying a phase-colored
	left border, followed by a full-width hitbox card reading the shape and its live dimensions.

	ALWAYS VISIBLE, unlike StatsPanel.lua. This is not a duplicate of that module and does not replace
	it: StatsPanel is the Stats SECTION -- a full analytical read (projected DPS, damage events,
	per-phase series, measured test-fire results) that an author navigates to deliberately. This is
	the reference's at-a-glance readout that sits under the preview the whole time, so the six numbers
	you tune most often are legible while you are tuning them, without leaving the section you are in.
	The split is the reference's own: it shows both, in different panes, at the same time.

	Reads straight off the draft rather than through MoveStats.Project. Every value here is a stored
	field or a trivial format of one, so projecting would buy nothing and would couple this readout to
	a report shape that exists to answer much harder questions (what this move does over time, against
	what). StatsPanel is the consumer that genuinely needs Project.

	The left-border color is the reference's phase vocabulary (EditorTokens.Phase), reused so a card
	and the timeline segment it describes are the same hue -- Windup violet, Active crimson, Recovery
	blue. Damage borrows Active's crimson and Knockback borrows Recovery's blue rather than
	introducing two more colors, matching the reference's own palette reuse.

	Does not own: the phase colors (EditorTokens), the analytical read (StatsPanel), or the 3D preview
	itself (PreviewViewport, which mounts this beneath its viewport).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local EditorTokens = require(script.Parent.EditorTokens)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type MoveDefinition = MoveTypes.MoveDefinition

local MoveStatsGrid = {}

local CARD_HEIGHT = 42
local CARD_GAP = Tokens.Space.XS
local BORDER_WIDTH = 2
local CARD_PADDING = Tokens.Space.S

-- One stat card: a colored left rule, a dim caption, and the value under it. The rule is a child
-- Frame rather than a UIStroke because only ONE edge is colored -- a stroke would outline all four.
local function statCard(
	scope: Scope,
	caption: string,
	value: Fusion.UsedAs<string>,
	accent: Color3,
	layoutOrder: number,
	widthScale: number
): Frame
	return scope:New "Frame" {
		Name = "Stat_" .. caption,
		LayoutOrder = layoutOrder,
		Size = UDim2.new(widthScale, if widthScale < 1 then -CARD_GAP / 2 else 0, 0, CARD_HEIGHT),
		BackgroundColor3 = Tokens.Wash.Inset.Color,
		BackgroundTransparency = Tokens.Wash.Inset.Transparency,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "Frame" {
				Name = "Accent",
				Size = UDim2.new(0, BORDER_WIDTH, 1, 0),
				BackgroundColor3 = accent,
				BorderSizePixel = 0,
			},
			Inset(scope, { Y = Tokens.Space.XS, Left = BORDER_WIDTH + CARD_PADDING, Right = CARD_PADDING }),
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = caption,
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.new(1, 0, 0, 12),
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = value,
				Scale = "Numeral",
				Color = Tokens.Color.TextPrimary,
				Size = UDim2.new(1, 0, 0, 16),
				LayoutOrder = 2,
			}),
		},
	} :: Frame
end

-- Formats whichever measurements the CURRENT shape actually uses. Box reads X/Y/Z, Sphere reads a
-- single radius; every other shape falls through to its own name rather than printing a Box's
-- dimensions for a shape that does not have them -- HitboxShapes.FieldsFor owns the real per-shape
-- field list, and reproducing it here would be a second copy to keep in sync for a readout.
local function dimensionText(draft: MoveDefinition?): string
	if not draft then
		return ""
	end
	local d = draft.Dimensions
	if not d then
		return ""
	end
	-- Width/Height/Depth, NOT SizeX/SizeY/SizeZ. Those three names have never existed on
	-- HitboxShapes.Dimensions (see that module's own Dimensions type and Box's Fields list) -- reading
	-- them handed string.format three nils and threw "invalid argument #2 to 'format' (number
	-- expected, got nil)" on every draft change for a Box move, which is every hand-authored attack in
	-- the game. Nil-guarded as well as renamed: Dimensions only carries the fields the CURRENT shape
	-- uses, so a draft caught mid-shape-change legitimately has none of them yet, and a stats readout
	-- must degrade to a dash rather than take the editor's whole reactive graph down with it.
	if draft.Shape == "Box" then
		if not (d.Width and d.Height and d.Depth) then
			return "--"
		end
		return string.format("W %.1f   H %.1f   D %.1f", d.Width, d.Height, d.Depth)
	elseif draft.Shape == "Sphere" then
		if not d.Radius then
			return "--"
		end
		return string.format("R %.1f", d.Radius)
	end
	return "see Hitbox section"
end

local function textOf(scope: Scope, draft: Fusion.UsedAs<MoveDefinition?>, format: (MoveDefinition) -> string)
	return scope:Computed(function(use)
		local d = use(draft)
		return if d then format(d) else "--"
	end)
end

function MoveStatsGrid.Build(scope: Scope, draft: Fusion.UsedAs<MoveDefinition?>, layoutOrder: number): Frame
	local phase = EditorTokens.Phase

	local cards: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			Padding = UDim.new(0, CARD_GAP),
			VerticalAlignment = Enum.VerticalAlignment.Top,
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
		statCard(
			scope,
			"Damage",
			textOf(scope, draft, function(d)
				return string.format("%d", d.Damage)
			end),
			phase.Active,
			1,
			0.5
		),
		statCard(
			scope,
			"Knockback",
			textOf(scope, draft, function(d)
				-- "None" rather than 0: knockback is an optional sub-table, and a move without one is
				-- categorically different from one authored to launch nobody.
				return if d.Knockback then string.format("%d", d.Knockback.HorizontalVelocity) else "None"
			end),
			phase.Recovery,
			2,
			0.5
		),
		statCard(
			scope,
			"Windup",
			textOf(scope, draft, function(d)
				return `{EditorTokens.ToFrames(d.WindupSeconds)}f`
			end),
			phase.Windup,
			3,
			0.5
		),
		statCard(
			scope,
			"Active",
			textOf(scope, draft, function(d)
				return `{EditorTokens.ToFrames(d.ActiveSeconds)}f`
			end),
			phase.Active,
			4,
			0.5
		),
		statCard(
			scope,
			"Recovery",
			textOf(scope, draft, function(d)
				return `{EditorTokens.ToFrames(d.RecoverySeconds)}f`
			end),
			phase.Recovery,
			5,
			0.5
		),
		-- Cooldown reads in SECONDS while the three phases read in frames, exactly as the reference
		-- does -- see PropertyEditor's frameField for why cooldown is deliberately not a frame count.
		statCard(
			scope,
			"Cooldown",
			textOf(scope, draft, function(d)
				return string.format("%.2fs", d.Cooldown)
			end),
			EditorTokens.Accent,
			6,
			0.5
		),
	}

	return scope:New "Frame" {
		Name = "MoveStatsGrid",
		LayoutOrder = layoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, CARD_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = "MOVE STATS",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, 14),
				LayoutOrder = 1,
			}),
			scope:New "Frame" {
				Name = "Cards",
				LayoutOrder = 2,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,

				[Children] = cards,
			},
			-- Full width, and last: the hitbox line is the one stat that is a pair of readings
			-- (shape AND its measurements) rather than a single number, so it does not fit the
			-- half-width card shape the six above share.
			statCard(
				scope,
				"Hitbox",
				scope:Computed(function(use)
					local d = use(draft)
					if not d then
						return "--"
					end
					return `{d.Shape}   {dimensionText(d)}`
				end),
				EditorTokens.Accent,
				3,
				1
			),
		},
	} :: Frame
end

return MoveStatsGrid
