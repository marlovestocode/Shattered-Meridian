--!strict
--[[
	StepRail.lua

	Owns: the step-rail chrome pinned to the top of every "creator" screen's CreatorFrame
	(docs/design/intro-redesign-figma-spec.md section 3.4) -- three numbered steps (Origin/
	Attributes/Name) plus a fourth, unnumbered "seal" for Confirmation. Per the designer: 3 steps +
	a seal, not five (Cinematic is a chromeless prologue and carries no rail entry at all) and not
	two (Confirmation is real chrome, not folded into step 3). Derives which step is active purely
	from OnboardingTypes.Stage -- no separate "current step index" state exists anywhere.

	The seal lights up in AccentSecondary (bronze), not AccentPrimary (violet) -- the one deliberate
	color deviation from the numbered steps' violet, matching docs/ui-ux-philosophy.md's own split
	("violet is interactive/live, bronze is committed/permanent"): Confirmation is the one stage in
	this flow that's ABOUT the character becoming permanent, so its rail entry gets the "permanent"
	accent rather than the "in-progress" one.

	Three visual states, not the spec's binary Active/Inactive -- Completed (before the active step)
	is real chrome, not just a dimmer copy of Inactive, because it's also the one state that's
	clickable: a real TextButton that fires NavigateRequested with its own Stage, jumping straight
	there rather than forcing N presses of Back. This needed one new shared signal
	(NavigateRequested, threaded through OnboardingHandle and every screen's own Props) rather than
	reusing an existing BackRequested event -- BackRequested only ever means "one step back," and
	firing it repeatedly to simulate a multi-step jump would desync from what the rail visually
	promised (click "1 ORIGIN" from Confirmation, land on NameEntry instead) -- dishonest UI is worse
	than a small amount of new plumbing. Upcoming steps (after the active one) are not clickable --
	this flow doesn't support skipping ahead.

	Does not own navigation itself -- exactly like ContinueRequested/BackRequested elsewhere in this
	folder, this only fires the signal; OnboardingClient.lua is the one thing that ever calls
	handle.Stage:set(...).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local TrackedLabel = require(script.Parent.Parent.Parent.Components.TrackedLabel)
local OnboardingTypes = require(script.Parent.Types)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Stage = OnboardingTypes.Stage

export type StepRailProps = {
	Stage: Stage,
	-- Appended to the ACTIVE step's own label as " -- {reason}" in bronze (spec: "2 ATTRIBUTES · 4
	-- LEFT"). Reactive (unlike everything else on this rail) -- omit, or let it read "", for a step
	-- with nothing left to report.
	BlockingReason: UsedAs<string>?,
	NavigateRequested: BindableEvent,
	LayoutOrder: UsedAs<number>?,
}

type StepStatus = "Completed" | "Active" | "Upcoming"

type StepDefinition = { Stage: Stage, Number: string, Label: string }

local STEPS: { StepDefinition } = {
	{ Stage = "RaceSelect", Number = "1", Label = "ORIGIN" },
	{ Stage = "Attributes", Number = "2", Label = "ATTRIBUTES" },
	{ Stage = "NameEntry", Number = "3", Label = "NAME" },
}

-- Cinematic (0) has no rail entry at all -- see file header. Included here only so STAGE_ORDER
-- covers every Stage value, keeping the lookup total under --!strict.
local STAGE_ORDER: { [Stage]: number } = {
	Cinematic = 0,
	RaceSelect = 1,
	Attributes = 2,
	NameEntry = 3,
	Confirmation = 4,
}

local RAIL_HEIGHT = 41 -- the design's own number (docs/design/intro-redesign-figma-spec.md 3.4).
local NUMBER_BOX_SIZE = 20
local CONNECTOR_WIDTH = 32
local SEAL_SIZE = 14
-- Widest the active step's blocking reason ever needs (" -- 16 LEFT", the longest string Attributes
-- can produce, at Detail/11px). Fixed rather than automatic -- see NumberedStep's own reasonSize
-- comment for why an automatically-sized width is structurally unsafe in this particular slot.
local REASON_WIDTH = 72

local function Connector(scope: Scope, layoutOrder: number): Frame
	return Divider.Plain(scope, {
		Size = UDim2.fromOffset(CONNECTOR_WIDTH, 1),
		LayoutOrder = layoutOrder,
	})
end

local function NumberedStep(
	scope: Scope,
	definition: StepDefinition,
	status: StepStatus,
	blockingReason: UsedAs<string>?,
	navigateRequested: BindableEvent,
	layoutOrder: number
): TextButton
	local numberColor = if status == "Active"
		then Tokens.Color.AccentPrimaryBright
		elseif status == "Completed" then Tokens.Color.TextPrimary
		else Tokens.Color.TextDisabled
	local strokeColor = if status == "Active"
		then Tokens.Color.AccentPrimary
		elseif status == "Completed" then Tokens.Border.Lit.Color
		else Tokens.Border.Standard.Color
	local strokeTransparency = if status == "Active"
		then 0
		elseif status == "Completed" then Tokens.Border.Lit.Transparency
		else Tokens.Border.Standard.Transparency
	-- Active gets the accent fill (spec: "background var(--qi-dim)"); Completed reads as "done" via
	-- its brighter border/number alone, with no fill, so it's tellable apart from the one step
	-- that's actually current.
	local fillTransparency = if status == "Active" then Tokens.Wash.AccentFill.Transparency else 1
	local labelColor = if status == "Upcoming" then Tokens.Color.TextDisabled else Tokens.Color.TextSecondary

	local labelChildren: { Instance } = {
		TrackedLabel(scope, {
			Text = definition.Label,
			Scale = "Micro",
			Color = labelColor,
			LayoutOrder = 1,
		}),
	}
	if status == "Active" and blockingReason ~= nil then
		local reasonText = scope:Computed(function(use)
			local reason = use(blockingReason :: UsedAs<string>)
			return if reason == "" then "" else ` -- {reason}`
		end)
		-- An EXPLICIT Size, and therefore AutomaticSize.None (Label.lua derives one from the other).
		-- Load-bearing, not cosmetic. Label.lua's no-Size default is `UDim2.fromScale(1, 0)` +
		-- AutomaticSize.XY -- "as wide as my parent" -- and this label's parent (the "Label" frame
		-- below) is itself AutomaticSize.X, i.e. "as wide as the sum of my children." That pair is
		-- circular, and Roblox resolves it by letting the two diverge instead of settling, blowing this
		-- one label out to hundreds of pixels. The rail's total content then ran far past the 800px
		-- panel, and because Items' UIListLayout is center-aligned the overflow spilled symmetrically
		-- off BOTH sides: step 1 rendered off the left edge of the screen, step 3 and the seal off the
		-- right. Only ever reachable on Attributes -- the one stage that passes a BlockingReason at all
		-- -- which is exactly why the Origin step always looked correct.
		local reasonSize = scope:Computed(function(use)
			-- Collapses to zero rather than holding the slot open once the reason clears: the rail is
			-- center-aligned, so permanently reserving REASON_WIDTH would visibly shove every step
			-- sideways to make room for text that isn't being drawn.
			return if use(reasonText) == ""
				then UDim2.fromOffset(0, RAIL_HEIGHT)
				else UDim2.fromOffset(REASON_WIDTH, RAIL_HEIGHT)
		end)
		table.insert(
			labelChildren,
			-- Plain Label, not TrackedLabel, despite the rest of this row being tracked caps -- this
			-- is the one piece of text on the whole rail that changes live (Attributes' "4 LEFT" as
			-- the player spends points), and TrackedLabel fundamentally can't re-render reactively
			-- (see that file's own header). A 1px size mismatch against the tracked step name is the
			-- accepted cost of the reason text actually staying correct.
			Label(scope, {
				Text = reasonText,
				Scale = "Detail",
				Color = Tokens.Color.AccentSecondary,
				Size = reasonSize,
				LayoutOrder = 2,
			})
		)
	end

	return scope:New "TextButton" {
		Name = definition.Stage,
		LayoutOrder = layoutOrder,
		Size = UDim2.fromOffset(0, RAIL_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Active = status == "Completed",

		[OnEvent "Activated"] = function()
			if status == "Completed" then
				navigateRequested:Fire(definition.Stage)
			end
		end,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "NumberBox",
				Size = UDim2.fromOffset(NUMBER_BOX_SIZE, NUMBER_BOX_SIZE),
				BackgroundColor3 = Tokens.Wash.AccentFill.Color,
				BackgroundTransparency = fillTransparency,
				BorderSizePixel = 0,
				LayoutOrder = 1,

				[Children] = {
					scope:New "UICorner" {
						CornerRadius = Tokens.Radius.Sharp,
					},
					scope:New "UIStroke" {
						Color = strokeColor,
						Transparency = strokeTransparency,
						Thickness = 1,
					},
					TrackedLabel(scope, {
						Text = definition.Number,
						Scale = "Abbrev",
						Color = numberColor,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
					}),
				},
			},
			scope:New "Frame" {
				Name = "Label",
				Size = UDim2.fromOffset(0, RAIL_HEIGHT),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(labelChildren),
				},
			},
		},
	} :: TextButton
end

local function Seal(scope: Scope, isActive: boolean, layoutOrder: number): Frame
	-- Bronze, not violet -- see file header.
	local color = if isActive then Tokens.Color.AccentSecondary else Tokens.Color.TextDisabled
	return scope:New "Frame" {
		Name = "ConfirmationSeal",
		LayoutOrder = layoutOrder,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(SEAL_SIZE, SEAL_SIZE),
		Rotation = 45,
		BackgroundColor3 = color,
		BackgroundTransparency = if isActive then 0.85 else 1,
		BorderSizePixel = 0,

		[Children] = scope:New "UIStroke" {
			Color = color,
			Thickness = 1,
		},
	} :: Frame
end

-- A table, not a bare function -- same shape as Components/VitalIcon.lua's own VitalIcon.new, and
-- for the identical reason: CreatorFrame.lua (the one caller) needs RAIL_HEIGHT to compute the
-- Body slot's own height and must not re-guess or duplicate this file's own number to do it.
local StepRailModule = {}
StepRailModule.RAIL_HEIGHT = RAIL_HEIGHT

function StepRailModule.Mount(scope: Scope, props: StepRailProps): Frame
	local activeOrder = STAGE_ORDER[props.Stage]

	local items: { Instance } = {}
	for index, definition in ipairs(STEPS) do
		local stepOrder = STAGE_ORDER[definition.Stage]
		local status: StepStatus = if stepOrder < activeOrder
			then "Completed"
			elseif stepOrder == activeOrder then "Active"
			else "Upcoming"

		table.insert(
			items,
			NumberedStep(scope, definition, status, props.BlockingReason, props.NavigateRequested, index * 2 - 1)
		)
		table.insert(items, Connector(scope, index * 2))
	end
	-- The seal has no NumberedStep-style click target -- Confirmation is the last stage, so there is
	-- no "past the seal, click to return" case the way there is for the three numbered steps.
	table.insert(
		items,
		scope:New "Frame" {
			Name = "SealSlot",
			LayoutOrder = #STEPS * 2 + 1,
			Size = UDim2.fromOffset(SEAL_SIZE, RAIL_HEIGHT),
			BackgroundTransparency = 1,
			[Children] = Seal(scope, props.Stage == "Confirmation", 1),
		}
	)

	return scope:New "Frame" {
		Name = "StepRail",
		Size = UDim2.new(1, 0, 0, RAIL_HEIGHT),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Wash.RailScrim.Color,
		BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,
		BorderSizePixel = 0,

		[Children] = {
			-- A direct sibling of Items below, not a child of it -- Items owns the horizontal
			-- UIListLayout for the step buttons/connectors/seal, and a UIListLayout arranges EVERY
			-- GuiObject sibling under it, not just its "intended" list items. This absolutely-positioned
			-- bottom rule must live outside that layout's reach, one level up, or (at nearly full rail
			-- width) it gets forced into the horizontal flow as its own oversized flex item and pushes
			-- every step past the rail's visible bounds (see Attributes.lua's AttributeRow -- Content
			-- fix for the identical bug already caught there).
			Divider.Plain(scope, {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, 1),
			}),
			scope:New "Frame" {
				Name = "Items",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.L),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(items),
				},
			},
		},
	} :: Frame
end

return StepRailModule
