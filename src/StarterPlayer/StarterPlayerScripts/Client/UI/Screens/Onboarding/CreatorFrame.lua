--!strict
--[[
	CreatorFrame.lua

	Owns: the shared 800x640 panel shell every "creator" stage (RaceSelect/Attributes/NameEntry/
	Confirmation -- NOT Cinematic, which is deliberately chromeless, see Cinematic.lua's header) is
	built inside: the textured, corner-bracketed Panel.lua instance, its StepRail band, and
	the Header/scrolling-Body/Footer slot split. Every current pre-redesign screen hardcoded its own
	offset width (640/560/480/520) and overflowed small viewports -- this is the fix, mirroring
	Screens/DevMenu/init.lua's root-panel role: it owns the top-level layout budget and hands each
	slot a size, but has no opinion on what's INSIDE Header/Body/Footer beyond their own dimensions.

	Sized via `UDim2.new(1, -Space.XXL*2, 1, -Space.XXL*2)` (Scale-relative to the viewport, not a
	bare `fromOffset`) plus a UISizeConstraint capping the resolved size at the design's own 800x640 --
	so the panel is exactly 800x640 on anything large enough to fit it, and shrinks gracefully (rather
	than overflowing) on anything smaller. A full mobile pass (docs/design/intro-redesign-handoff.md
	Phase F) is still a separate, later step; this only fixes the "overflows a small viewport" bug,
	it doesn't yet retarget touch ergonomics.

	Rail/Header/Footer are explicit, spelled-out pixel budgets; Body is not, and used to be. This file's
	header used to state that "Roblox's UIListLayout has no flex-grow, so the one section that should
	fill the rest still needs its height computed from the other three" -- which was true when it was
	written and is not any more. UIFlexItem is the engine's own flex-grow, and Components/Stack.lua's
	Fill is one line of it, so Body now asks the layout what is left instead of this file predicting it
	from three numbers (one of which, HeaderHeight, is a per-screen prop each caller passes in, so the
	prediction was only ever as good as every caller's own arithmetic).

	Does not own StepRail's own content (built internally from Stage/BlockingReason/
	StepRailNavigateRequested, but see StepRail.lua for what it renders) or what a caller puts in the
	Header/Body/Footer slots -- those are this file's one real per-screen variation point.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local StepRail = require(script.Parent.StepRail)
local OnboardingTypes = require(script.Parent.Types)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type CreatorFrameProps = {
	Stage: OnboardingTypes.Stage,
	StepRailNavigateRequested: BindableEvent,
	-- See StepRail.lua's own BlockingReason comment -- reactive, shown beside the active step only.
	BlockingReason: UsedAs<string>?,
	-- Each screen's header content differs in shape (RaceSelect's centered title, Attributes' left
	-- eyebrow+title), so its height is caller-supplied rather than guessed -- see file header.
	HeaderHeight: number,
	HeaderContent: UsedAs<{ Instance }>?,
	BodyContent: UsedAs<{ Instance }>?,
	FooterHint: UsedAs<string>?,
	FooterButtons: UsedAs<{ Instance }>?,
}

-- Panel clearance from the viewport edge on every side, and the design's own cap
-- (docs/design/intro-redesign-figma-spec.md section 3: "max-width: 800px; min-height: 640px").
local PANEL_MARGIN = Tokens.Space.XXL
local MAX_SIZE = Vector2.new(800, 640)

-- The redesign's brackets want 16px arms, not Panel.lua's own pre-redesign 12px default -- see that
-- file's own BracketArmLength comment for why the default itself didn't change.
local BRACKET_ARM_LENGTH = 16

-- Footer band height: Tokens.Control.RowHeight (40, the button row) plus the spec's own "py-5"
-- (20px) top AND bottom -- reached by centering Footer's content vertically in an 80px band rather
-- than an explicit UIPadding, so the two numbers combine here instead of needing their own Tokens
-- entry (neither 20 nor 80 recurs anywhere else in this UI).
local FOOTER_HEIGHT = 40 + 20 * 2

local function CreatorFrame(scope: Scope, props: CreatorFrameProps): Frame
	local panel = Panel(scope, {
		Name = "CreatorFrame",
		-- Fills the wrapper below exactly -- the wrapper, not this Panel, owns centering/margin/cap,
		-- because a UISizeConstraint clamps whatever Frame it's DIRECTLY parented to, and Panel.lua
		-- parents a caller's Children under its own inner "Content" wrapper, one level below the
		-- Frame it actually sizes via Size/AnchorPoint/Position. Putting the constraint there would
		-- have clamped Content's size while the outer Panel (its fill, border, texture, brackets --
		-- everything actually painted) kept growing unconstrained. See file header.
		Size = UDim2.fromScale(1, 1),
		-- Was `Lattice = true`, which drew nothing at all: LatticeOverlay.lua needed an uploaded hex
		-- tile that was never produced. Panel's replacement layer (Components/MeridianField.lua) is
		-- procedural, so this creator panel finally has the surface grain the design always specified
		-- -- see MeridianField.lua's header on why the motif itself changed too.
		SurfaceTexture = true,
		CornerAccent = true,
		BracketArmLength = BRACKET_ARM_LENGTH,

		Children = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, 0), -- bands sit flush; their own hairline borders are the seam.
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			StepRail.Mount(scope, {
				Stage = props.Stage,
				BlockingReason = props.BlockingReason,
				NavigateRequested = props.StepRailNavigateRequested,
				LayoutOrder = 1,
			}),

			scope:New "Frame" {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, props.HeaderHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					Divider.Plain(scope, {
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.fromScale(0, 1),
						Size = UDim2.new(1, 0, 0, 1),
					}),
					props.HeaderContent,
				},
			},

			Stack.Fill(
				scope,
				ScrollArea(scope, {
					Name = "Body",
					Size = UDim2.fromScale(1, 1),
					LayoutOrder = 3,

					Children = props.BodyContent,
				})
			),

			scope:New "Frame" {
				Name = "Footer",
				Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
				BackgroundColor3 = Tokens.Wash.FooterScrim.Color,
				BackgroundTransparency = Tokens.Wash.FooterScrim.Transparency,
				BorderSizePixel = 0,
				LayoutOrder = 4,

				[Children] = {
					Divider.Plain(scope, {
						Size = UDim2.new(1, 0, 0, 1),
					}),
					scope:New "UIPadding" {
						PaddingLeft = UDim.new(0, Tokens.Space.XXL), -- "px-8"
						PaddingRight = UDim.new(0, Tokens.Space.XXL),
					},
					Label(scope, {
						Text = props.FooterHint or "",
						Scale = "Detail",
						Color = Tokens.Color.TextDisabled,
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
					}),
					scope:New "Frame" {
						Name = "Buttons",
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						Size = UDim2.fromOffset(0, Tokens.Control.RowHeight),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundTransparency = 1,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								VerticalAlignment = Enum.VerticalAlignment.Center,
								Padding = UDim.new(0, Tokens.Space.S),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							props.FooterButtons,
						},
					},
				},
			},
		},
	})

	-- The wrapper: owns centering + the responsive-with-a-cap size (see file header and the `panel`
	-- comment above for why this can't live on Panel itself). Scale-relative to the viewport minus a
	-- fixed margin, capped at the design's own 800x640 -- not a bare `fromOffset`, so the panel
	-- shrinks gracefully on a small viewport instead of overflowing it.
	return scope:New "Frame" {
		Name = "CreatorFrameWrapper",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -PANEL_MARGIN * 2, 1, -PANEL_MARGIN * 2),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UISizeConstraint" {
				MaxSize = MAX_SIZE,
			},
			panel,
		},
	} :: Frame
end

return CreatorFrame
