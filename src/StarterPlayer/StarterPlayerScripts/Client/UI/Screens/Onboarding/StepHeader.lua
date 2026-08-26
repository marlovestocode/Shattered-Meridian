--!strict
--[[
	Onboarding/StepHeader.lua

	Owns: the centred eyebrow/flourish + title + optional subtitle band at the top of a character
	creation step, AND the height that band needs -- which is the whole reason this is a module
	rather than a copied thirty lines.

	NameEntry, RaceSelect and Confirmation each held a byte-identical `Header(scope)` -- same Frame,
	same Inset, same UIListLayout -- differing only in whether the first child was a tracked eyebrow
	or a Divider.Flourish, and whether a subtitle followed the title. Each ALSO held its own
	hand-summed HEADER_HEIGHT to tell CreatorFrame how tall to make the band, spelled out longhand
	as `32 + 24 + 8 + 9 + 28` with a comment naming each term.

	AND ONE OF THOSE SUMS WAS WRONG. NameEntry budgeted 28 for its title, and its title is authored at
	36 -- so its header band came up eight pixels short of its own content, quietly eating most of the
	gap under the title. Nothing errors, nothing logs, and the comment above the constant confidently
	describes the arithmetic it does not do. That is exactly the failure CLAUDE.md's Stack.Fill entry
	describes for hand-summed allowances, arrived at from the other direction: here the container asks
	its caller how tall to be, so the caller has to know every child's height and keep knowing.

	Height() closes it by deriving the sum from the SAME spec New() builds from. A screen can no
	longer describe one header and budget for another.

	Does not own: the band itself (CreatorFrame.lua takes HeaderHeight and HeaderContent and lays the
	step out), the step pip rail (StepRail.lua), or Attributes.lua's header -- that one is a genuinely
	different two-column layout with a reset control pinned right, not this shape with different text.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local TrackedLabel = require(script.Parent.Parent.Parent.Components.TrackedLabel)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

local StepHeader = {}

-- Every term of the sum, in one place, named. These mirror what New() below actually authors -- a
-- change to either must be a change to both, which is the point of them living beside each other.
local PADDING_TOP = Tokens.Space.XXL
local PADDING_BOTTOM = Tokens.Space.XL
local GAP = Tokens.Space.S
local EYEBROW_HEIGHT = 9
local FLOURISH_HEIGHT = 6
local TITLE_HEIGHT = 36
local SUBTITLE_HEIGHT = 36

local FLOURISH_SIZE = UDim2.fromOffset(160, FLOURISH_HEIGHT)

-- A step's header, described rather than built. Exactly one of Eyebrow/Flourish is expected: the two
-- are the same slot (the thing above the title) drawn two ways, and the three live steps split two
-- to one between them.
export type StepHeaderSpec = {
	-- Tracked all-caps line above the title, e.g. "CHARACTER CREATION -- STEP 3". Confirmation
	-- deliberately carries no step number -- see StepRail.lua's own header on why it is the lit seal
	-- rather than "step 4".
	Eyebrow: string?,
	-- A Divider.Flourish in the eyebrow's place instead.
	Flourish: boolean?,
	Title: string,
	Subtitle: string?,
}

local function leadingHeight(spec: StepHeaderSpec): number
	if spec.Eyebrow then
		return EYEBROW_HEIGHT
	end
	if spec.Flourish then
		return FLOURISH_HEIGHT
	end
	return 0
end

-- What CreatorFrame's HeaderHeight should be for this spec. Derived from the same fields New() reads,
-- so the two cannot disagree the way three hand-written sums could -- and did.
function StepHeader.Height(spec: StepHeaderSpec): number
	local leading = leadingHeight(spec)
	local count = (if leading > 0 then 1 else 0) + 1 + (if spec.Subtitle then 1 else 0)
	local content = leading + TITLE_HEIGHT + (if spec.Subtitle then SUBTITLE_HEIGHT else 0)
	return PADDING_TOP + PADDING_BOTTOM + GAP * math.max(count - 1, 0) + content
end

function StepHeader.New(scope: Scope, spec: StepHeaderSpec): Frame
	local children: { Instance } = {
		Inset(scope, { X = Tokens.Space.XXXL, Top = PADDING_TOP, Bottom = PADDING_BOTTOM }),
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}

	if spec.Eyebrow then
		table.insert(
			children,
			TrackedLabel(scope, {
				Text = spec.Eyebrow,
				Scale = "Eyebrow",
				Color = Tokens.Color.TextDisabled,
				LayoutOrder = 1,
			})
		)
	elseif spec.Flourish then
		table.insert(children, Divider.Flourish(scope, { Size = FLOURISH_SIZE, LayoutOrder = 1 }))
	end

	table.insert(
		children,
		Label(scope, {
			Text = spec.Title,
			Scale = "Title",
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, TITLE_HEIGHT),
			LayoutOrder = 2,
		})
	)

	if spec.Subtitle then
		table.insert(
			children,
			Label(scope, {
				Text = spec.Subtitle,
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextWrapped = true,
				Size = UDim2.new(1, 0, 0, SUBTITLE_HEIGHT),
				LayoutOrder = 3,
			})
		)
	end

	return scope:New "Frame" {
		Name = "Header",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,

		[Children] = children,
	} :: Frame
end

return StepHeader
