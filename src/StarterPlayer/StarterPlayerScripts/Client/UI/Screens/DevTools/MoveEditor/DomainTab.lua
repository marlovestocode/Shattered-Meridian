--!strict
--[[
	MoveEditor/DomainTab.lua

	Owns: the five pages a DOMAIN EXPANSION gets instead of Hitbox and Impact -- authoring the
	MoveDefinition.Domain block that makes a move open a realm (Shared/Domain/DomainTypes.lua). Since
	2026-10-07 they are one top-level Realm tab with a sub-tab bar over these five (init.lua), not five tabs.
	The move ids its effects and overrides name are picked from the move list (Fields.MovePicker): a Volley's
	from the projectile moves, an override's from the other realms. The five:

	    Realm     AT A GLANCE (the cast laid end to end), CHECKS, START FROM (archetypes), then the realm's
	              own clock, its cost and how many it governs
	    Boundary  its shape and size, its footprint, where it sits, who may cross it and how, what collapses it
	    Effects   STRIKE PRICE -- what the realm's OWN strike costs a body -- then up to DomainTypes
	              .MaxEffects periodic effects, each a kind of delivery through a system that already exists
	    Law       UNDER THIS LAW (the rules composed per kind of body), then up to DomainTypes.MaxRules rules
	    Clash     priority, behaviour toward a weaker realm, the tie-break, erosion, contest, MATCHUPS against
	              every other realm, and the per-opponent overrides

	A DOMAIN EXPANSION IS STILL A MOVE (DomainTypes' header), and it is shown that way. Its swing is the cast,
	so the Timing tab keeps its clip, windup, cooldown and locks (and reads its hints as the realm's); its art
	binding and name are the Identity tab's; its look and sound are the Presentation tab's four Realm
	moments; undo, save and Test swing are the readout's, as for any move. What changes is everything that
	described a VOLUME: a realm casts volumeless (HitboxTypes.AttackDefinition.Volumeless, set by
	MoveTypes.ToEngineAttackDefinition for any move with a Domain block), so the swing samples nothing in front
	of the caster, and the editor drops the Hitbox and Impact tabs for these five (init.lua's tab availability).

	ITS OWN WAY TO THE ATTACK RESOLVER is the Effects page's STRIKE PRICE: a Strike effect with no move id is
	priced by the domain move itself -- its Damage, Posture damage, Power level and Knockback, through the same
	AttackCatalog -> DamageSystem path a swing takes -- times the effect's Power. Those four fields are
	PriceFields', the same builder the Impact tab mounts, because they are the same four fields.

	WHAT THE PAGES SAY ABOUT A REALM IS DomainInsight's (2026-10-26): the lifecycle, pulse counts, the composed
	law, matchups and the checks are pure functions over the draft that call the runtime's own composition
	(DomainRules.Apply) and arbitration (DomainClash.Resolve) -- the pages only draw them. Every check names the
	page that holds its field; CHECKS lists them all with a Go to that page, and each page opens with a line
	for the errors and warnings that are its own. One Diagnostics Computed serves all five (init.lua builds it
	with the Realm tab), so a draft edit runs the checks once.

	THE LISTS ARE FIXED SLOTS, BUILT ON DEMAND. Each slot is a Fields.Section shown while the slot exists
	(index <= #list) and built the first time it is shown open, so a realm with two effects has built two
	effects' fields, not six (the old single Domain tab mounted all ~300 slot fields up front). Built once, a
	slot is kept and only toggles, so adding an entry never rebuilds the page under the cursor. A slot is
	bound to its INDEX, not to an entry, so moving an entry up or down (or duplicating it) is a plain list
	edit: the slots simply read their new entries. Adding is a chip per kind (the entry arrives with a
	magnitude that means something for that kind); each slot's row moves, duplicates or removes its own.
	Every edit goes through the context's one Edit, so all of it undoes.

	Choosing the move type is the type bar's (init.lua): it seeds DomainTypes.Defaults() -- a working realm,
	never a zero-length one -- and drops any grab or projectile block (Validate refuses a grab on a realm).
	These pages are only offered while the block exists, so nothing here creates or removes it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainGeometry = require(ReplicatedStorage.Shared.Domain.DomainGeometry)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatusTag = require(script.Parent.Parent.Parent.Parent.Components.StatusTag)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)

local Copy = require(script.Parent.Copy)
local DomainInsight = require(script.Parent.DomainInsight)
local Fields = require(script.Parent.Fields)
local PriceFields = require(script.Parent.PriceFields)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Move = MoveTypes.MoveDefinition
type DomainSpec = DomainTypes.DomainSpec
type Option = Fields.Option
type Diagnostic = DomainInsight.Diagnostic

local DOMAIN_LIMITS = DomainTypes.Limits
local HINTS = Copy.Domain.Hints

local options = Fields.OptionsOf
local trim = DomainInsight.Trim

local SHAPE_OPTIONS = options(DomainTypes.Shapes)
local ANCHOR_OPTIONS = options(DomainTypes.Anchors, { Fixed = "Fixed", FollowOwner = "Follow owner" })
local RULE_OPTIONS = options(DomainTypes.BoundaryRules)
local FILTER_OPTIONS = options(DomainTypes.TargetFilters, Copy.Domain.TargetFilters)
local TYPE_OPTIONS =
	options(DomainTypes.TargetTypes, { Any = "Anyone", Players = "Players", NonPlayers = "Bots and dummies" })
local EFFECT_OPTIONS = options(DomainTypes.EffectKinds, Copy.Domain.EffectKindChips)
local ORIGIN_OPTIONS =
	options(DomainTypes.StrikeOrigins, { Above = "Above", Center = "The centre", Owner = "The owner", Ring = "A ring" })
local RULE_KIND_OPTIONS = options(DomainTypes.RuleKinds, Copy.Domain.RuleKinds)
local CLASH_OPTIONS = options(DomainTypes.ClashBehaviors, Copy.Domain.ClashBehaviorChips)
local TIE_OPTIONS =
	options(DomainTypes.TieBreaks, { Contest = "Contest", Older = "Older holds", Newer = "Newer claims" })
local ARCHETYPE_OPTIONS: { Option } = {}
local ARCHETYPE_DESCRIBE: { [string]: string } = {}
for _, archetype in DomainInsight.Archetypes do
	table.insert(ARCHETYPE_OPTIONS, { Value = archetype.Id, Text = archetype.Text })
	ARCHETYPE_DESCRIBE[archetype.Id] = archetype.Describe
end

-- The size buttons on the Boundary page: a radius, and the height a cylinder or box takes with it.
local SIZE_STEPS = {
	{ Text = "Close", Radius = 16 },
	{ Text = "Mid", Radius = 36 },
	{ Text = "Wide", Radius = 60 },
	{ Text = "Vast", Radius = 100 },
}

local SEVERITY_COLOR: { [string]: Color3 } = {
	Error = Tokens.Color.DangerBright,
	Warning = Tokens.Color.Warning,
	Note = Tokens.Color.TextSecondary,
}
local SEVERITY_TEXT: { [string]: string } = { Error = "ERROR", Warning = "WARN", Note = "NOTE" }
-- The page names a check may point at, as the sub-tab bar and the top-level tabs show them.
local PAGE_TEXT: { [string]: string } = {
	Realm = "Core",
	Boundary = "Boundary",
	Effects = "Effects",
	Law = "Law",
	Clash = "Clash",
	Presentation = "Presentation",
	Timing = "Timing",
}
-- How many checks the CHECKS list shows at once; past it, a count line says how many more.
local CHECK_ROWS = 10
-- How many other realms MATCHUPS reads out.
local MATCHUP_ROWS = 8

-- What the Realm tab's pages share beyond the form context (init.lua builds it with the Realm tab).
export type Tools = {
	-- Draws the realm's boundary on your own character (Client/DevTools/MoveEditor/HitboxWorldPreview.lua).
	ShowOnCharacter: Fusion.Value<boolean>,
	-- Every check the open realm fails (DomainInsight.Diagnostics), recomputed once per draft edit.
	Diagnostics: Fusion.Computed<{ Diagnostic }>,
	-- Every move the editor knows, by id, for the descriptions that follow a reference.
	MovesById: Fusion.Computed<DomainInsight.MovesById>,
	-- Shows a Realm page or a top-level tab by the name a check carries.
	ShowPage: (name: string) -> (),
}

-- The open move's realm. Every page is offered only while there is one (init.lua), but a field still reads
-- through this so a stale frame between a type change and the tab hand-over never indexes nil.
local function domainOf(move: Move): DomainSpec?
	return move.Domain
end

-- One page's field builders, bound to its scope and context.
local function binder(scope: Scope, context: Fields.FormContext, tools: Tools)
	local bind = {}

	-- A Computed over the open realm; false while there is none.
	function bind.When(predicate: (DomainSpec, Move) -> boolean): Fusion.Computed<boolean>
		return scope:Computed(function(use)
			local move = use(context.Draft)
			local domain = if move then move.Domain else nil
			return domain ~= nil and predicate(domain, move :: Move)
		end)
	end

	-- A Computed summary over the open realm; "" while there is none.
	function bind.Summary(describe: (DomainSpec, Move) -> string): Fusion.Computed<string>
		return scope:Computed(function(use)
			local move = use(context.Draft)
			local domain = if move then move.Domain else nil
			return if domain then describe(domain, move :: Move) else ""
		end)
	end

	-- A summary that also reads the move list (a description that names another move).
	function bind.Described(describe: (DomainSpec, Move, DomainInsight.MovesById) -> string): Fusion.Computed<string>
		return scope:Computed(function(use)
			local move = use(context.Draft)
			local domain = if move then move.Domain else nil
			return if domain then describe(domain, move :: Move, use(tools.MovesById)) else ""
		end)
	end

	-- A number on the spec itself, or on an entry `entryOf` finds in it.
	function bind.Number(
		label: string,
		field: string,
		unit: string,
		steps: { number },
		decimals: number,
		order: number,
		shown: UsedAs<boolean>?,
		entryOf: ((DomainSpec) -> any)?,
		range: { Min: number, Max: number }?,
		hint: string?
	): Frame
		local bounds = range or DOMAIN_LIMITS[field]
		local function target(move: Move): any
			local domain = domainOf(move)
			if not domain then
				return nil
			end
			return if entryOf then entryOf(domain) else domain
		end
		return Fields.Number(scope, context, {
			Label = label,
			Unit = unit,
			Range = bounds,
			Steps = steps,
			Decimals = decimals,
			Hint = hint or (if entryOf then nil else HINTS[field]),
			Visible = shown,
			LayoutOrder = order,
			Get = function(move)
				local entry = target(move)
				return if entry then entry[field] else bounds.Min
			end,
			Set = function(move, value)
				local entry = target(move)
				if entry then
					entry[field] = value
				end
			end,
		})
	end

	function bind.Toggle(
		label: string,
		field: string,
		order: number,
		shown: UsedAs<boolean>?,
		entryOf: ((DomainSpec) -> any)?,
		hint: string?
	): Frame
		local function target(move: Move): any
			local domain = domainOf(move)
			if not domain then
				return nil
			end
			return if entryOf then entryOf(domain) else domain
		end
		return Fields.Toggle(scope, context, {
			Label = label,
			Hint = hint or (if entryOf then nil else HINTS[field]),
			Visible = shown,
			LayoutOrder = order,
			Get = function(move)
				local entry = target(move)
				return entry ~= nil and entry[field] == true
			end,
			Set = function(move, value)
				local entry = target(move)
				if entry then
					entry[field] = value
				end
			end,
		})
	end

	-- A closed choice as chips -- or, for a long list, a dropdown (`dropdown`).
	function bind.Choice(
		label: string,
		field: string,
		choices: { Option },
		order: number,
		shown: UsedAs<boolean>?,
		entryOf: ((DomainSpec) -> any)?,
		hint: UsedAs<string>?,
		dropdown: boolean?
	): Frame
		local function target(move: Move): any
			local domain = domainOf(move)
			if not domain then
				return nil
			end
			return if entryOf then entryOf(domain) else domain
		end
		local function get(move: Move): string
			local entry = target(move)
			return if entry then entry[field] else choices[1].Value
		end
		local function set(move: Move, value: string): ()
			local entry = target(move)
			if entry then
				entry[field] = value
			end
		end
		local hintText: UsedAs<string>? = hint or (if entryOf then nil else HINTS[field])
		if dropdown then
			return Fields.Choice(scope, context, {
				Label = label,
				Options = choices,
				Hint = hintText,
				Visible = shown,
				LayoutOrder = order,
				Get = get,
				Set = set,
			})
		end
		return Fields.Chips(scope, context, {
			Label = label,
			Options = choices,
			Hint = hintText,
			Visible = shown,
			LayoutOrder = order,
			Get = get,
			Set = set,
		})
	end

	function bind.MoveId(
		label: string,
		field: string,
		order: number,
		shown: UsedAs<boolean>?,
		entryOf: (DomainSpec) -> any,
		hint: string?,
		blankText: string?,
		accepts: ((entry: any, domain: DomainSpec?) -> boolean)?
	): Frame
		-- Picked from the move list, never typed (Fields.MovePicker).
		return Fields.MovePicker(scope, context, {
			Label = label,
			BlankText = blankText,
			Accepts = if accepts
				then function(entry)
					local move = Fusion.peek(context.Draft)
					return accepts(entry, if move then move.Domain else nil)
				end
				else nil,
			Hint = hint,
			Visible = shown,
			LayoutOrder = order,
			Get = function(move)
				local domain = domainOf(move)
				local entry = if domain then entryOf(domain) else nil
				return if entry then entry[field] else ""
			end,
			Set = function(move, value)
				local domain = domainOf(move)
				local entry = if domain then entryOf(domain) else nil
				if entry then
					entry[field] = value
				end
			end,
		})
	end

	-- One edit to the open realm.
	function bind.EditDomain(mutate: (DomainSpec, Move) -> ()): ()
		context.Edit(function(move)
			local domain = domainOf(move)
			if domain then
				mutate(domain, move)
			end
		end)
	end

	-- A read-out line in the primary text colour: what a slot or a section amounts to.
	function bind.Reading(text: UsedAs<string>, order: number, shown: UsedAs<boolean>?): Frame
		return Label(scope, {
			Text = text,
			Scale = "Detail",
			Color = Tokens.Color.TextPrimary,
			Size = UDim2.fromScale(1, 0),
			AutoHeight = true,
			TextWrapped = true,
			LineHeight = Tokens.Leading.Prose,
			LayoutOrder = order,
			Visible = shown,
		}) :: any
	end

	-- The errors and warnings that belong to `page`, as one line at the top of it -- nothing when there are
	-- none. Notes stay in CHECKS: a page should not open on a sentence about a setting that works.
	function bind.PageIssues(page: string, order: number): Frame
		local mine = scope:Computed(function(use): { Diagnostic }
			local picked: { Diagnostic } = {}
			for _, diagnostic in use(tools.Diagnostics) do
				if diagnostic.Page == page and diagnostic.Severity ~= "Note" then
					table.insert(picked, diagnostic)
				end
			end
			return picked
		end)
		return Label(scope, {
			Text = scope:Computed(function(use)
				local lines: { string } = {}
				for _, diagnostic in use(mine) do
					table.insert(lines, `{SEVERITY_TEXT[diagnostic.Severity]}  {diagnostic.Text}`)
				end
				return table.concat(lines, "\n")
			end),
			Scale = "Detail",
			Color = scope:Computed(function(use)
				for _, diagnostic in use(mine) do
					if diagnostic.Severity == "Error" then
						return Tokens.Color.DangerBright
					end
				end
				return Tokens.Color.Warning
			end),
			Size = UDim2.fromScale(1, 0),
			AutoHeight = true,
			TextWrapped = true,
			LineHeight = Tokens.Leading.Prose,
			LayoutOrder = order,
			Visible = scope:Computed(function(use)
				return #use(mine) > 0
			end),
		}) :: any
	end

	-- A run of fixed slots over one of the realm's lists (see this file's header): a section per slot, shown
	-- while that slot exists. Each slot's own body ends with its Up / Down / Copy / Remove row.
	function bind.Slots(
		spec: {
			Title: string,
			Max: number,
			FirstOrder: number,
			List: (DomainSpec) -> { any },
			-- The slot's folded summary; reads the move list for a description that names another move.
			Describe: (entry: any, domain: DomainSpec, moves: DomainInsight.MovesById) -> string,
			Build: (index: number) -> { Instance },
			-- The entry's DomainTypes field list, for Copy.
			EntryFields: { { Name: string } },
		}
	): { Instance }
		local built: { Instance } = {}
		for index = 1, spec.Max do
			table.insert(
				built,
				Fields.Section(scope, {
					Title = `{spec.Title} {index}`,
					Summary = bind.Described(function(domain, _, moves)
						local entry = spec.List(domain)[index]
						return if entry then spec.Describe(entry, domain, moves) else ""
					end),
					LayoutOrder = spec.FirstOrder + index,
					Visible = bind.When(function(domain)
						return index <= #spec.List(domain)
					end),
					Build = function()
						local fields = spec.Build(index)
						table.insert(
							fields,
							Fields.ButtonRow(scope, context, {
								Label = `{string.lower(spec.Title)} {index}`,
								LayoutOrder = 100,
								Buttons = {
									{
										Text = "Up",
										OnActivated = function()
											bind.EditDomain(function(domain)
												DomainInsight.Shift(spec.List(domain), index, -1)
											end)
										end,
									},
									{
										Text = "Down",
										OnActivated = function()
											bind.EditDomain(function(domain)
												DomainInsight.Shift(spec.List(domain), index, 1)
											end)
										end,
									},
									{
										Text = "Copy",
										OnActivated = function()
											bind.EditDomain(function(domain)
												DomainInsight.DuplicateAt(
													spec.List(domain),
													index,
													spec.Max,
													spec.EntryFields
												)
											end)
										end,
									},
									{
										Text = "Remove",
										OnActivated = function()
											bind.EditDomain(function(domain)
												local list = spec.List(domain)
												if list[index] then
													table.remove(list, index)
												end
											end)
										end,
									},
								},
								Hint = `Up and Down reorder; Copy inserts a duplicate below (while a slot is free); Remove drops it. Undo brings any of them back.`,
							})
						)
						return fields
					end,
				})
			)
		end
		return built
	end

	return bind
end

local DomainTab = {}

-- REALM ------------------------------------------------------------------------------------------------------

-- The lifecycle phases, in order, and how each is drawn on the strip.
local PHASES = {
	{ Key = "Windup", Text = "Cast windup", Color = Tokens.Color.TextDisabled, Transparency = 0.35 },
	{ Key = "Unfurl", Text = "Unfurl", Color = Tokens.Color.Warning, Transparency = 0.15 },
	{ Key = "Held", Text = "Held", Color = Tokens.Color.AccentPrimary, Transparency = 0 },
	{ Key = "Fold", Text = "Fold", Color = Tokens.Color.AccentPrimary, Transparency = 0.7 },
}
local STRIP_HEIGHT = 14
local MARKER_WIDTH = 2
local SWATCH = 8

-- The cast laid end to end, press to gone: a proportional strip of its four phases with the cancel window
-- and the cooldown marked on it, its key, and the totals under it.
local function lifecycle(scope: Scope, context: Fields.FormContext, order: number): Frame
	local life = scope:Computed(function(use): DomainInsight.Lifecycle?
		local move = use(context.Draft)
		if not move then
			return nil
		end
		local entry = use(context.Entry)
		local effective = if entry then entry.Effective else nil
		return DomainInsight.Lifecycle(move, effective)
	end)
	local function fraction(read: (DomainInsight.Lifecycle) -> number): Fusion.Computed<number>
		return scope:Computed(function(use)
			local value = use(life)
			if not value or value.Total <= 0 then
				return 0
			end
			return math.clamp(read(value) / value.Total, 0, 1)
		end)
	end

	local segments: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	local key: { Instance } = {}
	for index, phase in PHASES do
		local share = fraction(function(value)
			return (value :: any)[phase.Key]
		end)
		table.insert(
			segments,
			scope:New "Frame" {
				Name = phase.Key,
				Size = scope:Computed(function(use)
					return UDim2.fromScale(use(share), 1)
				end),
				BackgroundColor3 = phase.Color,
				BackgroundTransparency = phase.Transparency,
				BorderSizePixel = 0,
				LayoutOrder = index,
			}
		)
		table.insert(
			key,
			Stack.Row(scope, {
				Name = `Key_{phase.Key}`,
				Size = UDim2.new(0.25, -Tokens.Space.XS, 0, Tokens.Type.Detail.Size + Tokens.Space.XS),
				Gap = Tokens.Space.XS,
				AlignY = Enum.VerticalAlignment.Center,
				LayoutOrder = index,
				Children = {
					scope:New "Frame" {
						Name = "Swatch",
						Size = UDim2.fromOffset(SWATCH, SWATCH),
						BackgroundColor3 = phase.Color,
						BackgroundTransparency = phase.Transparency,
						BorderSizePixel = 0,
						LayoutOrder = 1,
					},
					Stack.Fill(
						scope,
						Label(scope, {
							Text = scope:Computed(function(use)
								local value = use(life)
								return if value then `{phase.Text} {trim((value :: any)[phase.Key])}s` else phase.Text
							end),
							Scale = "NumeralSmall",
							Color = Tokens.Color.TextSecondary,
							Size = UDim2.fromScale(0, 1),
							TextTruncate = Enum.TextTruncate.AtEnd,
							LayoutOrder = 2,
						})
					),
				},
			})
		)
	end

	local function marker(name: string, color: Color3, at: Fusion.Computed<number?>): Frame
		return scope:New "Frame" {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = scope:Computed(function(use)
				return UDim2.new(use(at) or 0, 0, 0, -3)
			end),
			Size = UDim2.new(0, MARKER_WIDTH, 1, 6),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 2,
			Visible = scope:Computed(function(use)
				return use(at) ~= nil
			end),
		} :: Frame
	end
	-- Both measured from the press: the cancel window opens CancelAfter into the realm, which opens at the
	-- end of the windup; the cooldown runs from the press (a marker only while it ends inside the strip).
	local cancelAt = scope:Computed(function(use): number?
		local value = use(life)
		if not value or value.Total <= 0 then
			return nil
		end
		return math.clamp((value.Windup + value.CancelAfter) / value.Total, 0, 1)
	end)
	local cooldownAt = scope:Computed(function(use): number?
		local value = use(life)
		if not value or value.Total <= 0 or value.Cooldown > value.Total then
			return nil
		end
		return value.Cooldown / value.Total
	end)

	local function fact(caption: string, read: (DomainInsight.Lifecycle) -> string, factOrder: number): Frame
		return Fields.Fact(
			scope,
			caption,
			scope:Computed(function(use)
				local value = use(life)
				return if value then read(value) else ""
			end),
			factOrder
		)
	end

	return Stack.New(scope, {
		Name = "Lifecycle",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.S,
		LayoutOrder = order,
		Children = {
			scope:New "Frame" {
				Name = "Strip",
				Size = UDim2.new(1, 0, 0, STRIP_HEIGHT),
				BackgroundColor3 = Tokens.Wash.TrackBase.Color,
				BackgroundTransparency = Tokens.Wash.TrackBase.Transparency,
				BorderSizePixel = 0,
				LayoutOrder = 1,
				[Fusion.Children] = {
					-- The segments sit in their own frame: the layout would sweep the markers into the run.
					scope:New "Frame" {
						Name = "Segments",
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						[Fusion.Children] = segments,
					},
					marker("CancelMarker", Tokens.Color.AccentPrimaryBright, cancelAt),
					marker("CooldownMarker", Tokens.Color.AccentSecondary, cooldownAt),
				},
			},
			Stack.Row(scope, {
				Name = "Key",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Gap = Tokens.Space.XS,
				LayoutOrder = 2,
				Children = key,
			}),
			fact("Press to gone", function(value)
				local windup = if value.Effective then "clip windup" else "authored windup"
				return `{trim(value.Total)}s  ({windup})`
			end, 3),
			fact("Cancel by pressing again", function(value)
				return `{trim(value.CancelAfter)}s after it opens (violet mark)`
			end, 4),
			fact("Cooldown", function(value)
				return if value.Cooldown > value.Total
					then `{trim(value.Cooldown)}s from the press (past the fold)`
					else `{trim(value.Cooldown)}s from the press (bronze mark)`
			end, 5),
			fact("Qi", function(value)
				local cost = if value.QiCost > 0 then `{trim(value.QiCost)} to cast` else "no cast cost"
				return if value.UpkeepTotal > 0
					then `{cost}  +  {trim(value.UpkeepTotal)} upkeep over the hold`
					else cost
			end, 6),
		},
	})
end

-- The CHECKS list: a fixed pool of rows over the open realm's diagnostics, each with a Go to its page.
local function checks(scope: Scope, tools: Tools, order: number): Frame
	local rows: { Instance } = {}
	for index = 1, CHECK_ROWS do
		local diagnostic = scope:Computed(function(use): Diagnostic?
			return use(tools.Diagnostics)[index]
		end)
		local function read(field: (Diagnostic) -> string): Fusion.Computed<string>
			return scope:Computed(function(use)
				local value = use(diagnostic)
				return if value then field(value) else ""
			end)
		end
		table.insert(
			rows,
			Stack.New(scope, {
				Name = `Check_{index}`,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Gap = Tokens.Space.XS,
				LayoutOrder = index,
				Visible = scope:Computed(function(use)
					return use(diagnostic) ~= nil
				end),
				Children = {
					Stack.Row(scope, {
						Name = "Head",
						Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
						Gap = Tokens.Space.S,
						AlignY = Enum.VerticalAlignment.Center,
						LayoutOrder = 1,
						Children = {
							StatusTag(scope, {
								Label = read(function(value)
									return SEVERITY_TEXT[value.Severity]
								end),
								Color = scope:Computed(function(use)
									local value = use(diagnostic)
									return if value then SEVERITY_COLOR[value.Severity] else Tokens.Color.TextSecondary
								end),
								LayoutOrder = 1,
							}),
							Stack.Fill(
								scope,
								Label(scope, {
									Text = read(function(value)
										return PAGE_TEXT[value.Page] or value.Page
									end),
									Scale = "NumeralSmall",
									Color = Tokens.Color.TextSecondary,
									Size = UDim2.fromScale(0, 1),
									LayoutOrder = 2,
								})
							),
							Button(scope, {
								Text = "Go",
								Size = UDim2.fromOffset(52, 28),
								LayoutOrder = 3,
								OnActivated = function()
									local value = peek(diagnostic)
									if value then
										tools.ShowPage(value.Page)
									end
								end,
							}),
						},
					}),
					Label(scope, {
						Text = read(function(value)
							return value.Text
						end),
						Scale = "Detail",
						Color = Tokens.Color.TextPrimary,
						Size = UDim2.fromScale(1, 0),
						AutoHeight = true,
						TextWrapped = true,
						LineHeight = Tokens.Leading.Prose,
						LayoutOrder = 2,
					}),
				},
			})
		)
	end
	table.insert(
		rows,
		Fields.Prose(
			scope,
			scope:Computed(function(use)
				local count = #use(tools.Diagnostics)
				if count == 0 then
					return "Nothing to report: every effect, rule and override reads as it will run."
				end
				return if count > CHECK_ROWS then `... and {count - CHECK_ROWS} more.` else ""
			end),
			CHECK_ROWS + 1,
			scope:Computed(function(use)
				local count = #use(tools.Diagnostics)
				return count == 0 or count > CHECK_ROWS
			end)
		)
	)
	return Stack.New(scope, {
		Name = "Checks",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.M,
		LayoutOrder = order,
		Children = rows,
	})
end

function DomainTab.Realm(
	scope: Scope,
	context: Fields.FormContext,
	visible: UsedAs<boolean>,
	tools: Tools
): ScrollingFrame
	local bind = binder(scope, context, tools)
	local hasArt = bind.When(function(_, move)
		return move.Art ~= nil
	end)
	local noArt = bind.When(function(_, move)
		return move.Art == nil
	end)

	return Fields.Page(scope, "RealmTab", visible, {
		Fields.Prose(scope, Copy.Domain.Realm, 1),
		Fields.Section(scope, {
			Title = "AT A GLANCE",
			Summary = bind.Summary(function(domain)
				return `{#domain.Effects} effects  ·  {#domain.Rules} rules  ·  {domain.Shape} R {trim(domain.Radius)}`
			end),
			LayoutOrder = 2,
			Build = function()
				return { lifecycle(scope, context, 1) }
			end,
		}),
		Fields.Section(scope, {
			Title = "CHECKS",
			Summary = scope:Computed(function(use)
				local tally = DomainInsight.Tally(use(tools.Diagnostics))
				return if tally == "" then "all clear" else tally
			end),
			LayoutOrder = 3,
			Build = function()
				return { checks(scope, tools, 1) }
			end,
		}),
		Fields.Section(scope, {
			Title = "START FROM",
			Summary = "archetypes",
			LayoutOrder = 4,
			StartClosed = true,
			Build = function()
				return {
					Fields.ActionChips(scope, context, {
						Label = "Archetype",
						Options = ARCHETYPE_OPTIONS,
						Describe = ARCHETYPE_DESCRIBE,
						Hint = Copy.Domain.Archetypes,
						LayoutOrder = 1,
						Apply = function(move, id)
							local archetype = DomainInsight.ArchetypeById(id)
							if archetype and move.Domain then
								archetype.Apply(move.Domain)
							end
						end,
					}),
					Fields.Prose(scope, Copy.Domain.Archetypes, 2),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "CLOCK",
			Summary = bind.Summary(function(domain)
				return string.format(
					"%gs unfurl  ·  %gs held  ·  %gs fold",
					domain.ActivationSeconds,
					domain.ActiveSeconds,
					domain.EndSeconds
				)
			end),
			LayoutOrder = 5,
			Build = function()
				return {
					bind.Number("Unfurl", "ActivationSeconds", "seconds", { 0.1, 0.5 }, 2, 1),
					bind.Number("Held for", "ActiveSeconds", "seconds", { 0.5, 5 }, 1, 2),
					bind.Number("Fold", "EndSeconds", "seconds", { 0.1, 0.5 }, 2, 3),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "COST",
			Summary = bind.Summary(function(domain, move)
				local cost = if move.Art then `{move.Art.QiCost} Qi` else "no Qi cost"
				return if domain.UpkeepQiPerSecond > 0
					then `{cost}  ·  {domain.UpkeepQiPerSecond} Qi/s upkeep`
					else cost
			end),
			LayoutOrder = 6,
			Build = function()
				return {
					Fields.Number(scope, context, {
						Label = "Qi cost",
						Unit = "Qi per cast",
						Range = ArtConstants.Limits.QiCost,
						Steps = { 5, 25 },
						Decimals = 0,
						Visible = hasArt,
						LayoutOrder = 1,
						Get = function(move)
							return if move.Art then move.Art.QiCost else 0
						end,
						Set = function(move, value)
							if move.Art then
								move.Art.QiCost = value
							end
						end,
					}),
					Fields.Prose(scope, Copy.Domain.QiCostNotArt, 2, noArt),
					bind.Number("Qi upkeep", "UpkeepQiPerSecond", "Qi per second", { 1, 5 }, 1, 3),
					bind.Reading(
						bind.Summary(function(domain)
							return if domain.UpkeepQiPerSecond > 0
								then `{trim(domain.UpkeepQiPerSecond * domain.ActiveSeconds)} Qi over a full hold, booked once a second. Running dry collapses the realm.`
								else "No upkeep: once cast, the realm costs nothing to hold."
						end),
						4
					),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "GOVERNS",
			Summary = bind.Summary(function(domain)
				return `up to {domain.MaxTargets} bodies`
			end),
			LayoutOrder = 7,
			Build = function()
				return {
					bind.Number("Max bodies", "MaxTargets", "bodies", { 1, 4 }, 0, 1),
				}
			end,
		}),
		Fields.Prose(scope, Copy.Domain.Presentation, 10),
	})
end

-- BOUNDARY ---------------------------------------------------------------------------------------------------

-- The open realm's boundary at the origin, centred CenterForward ahead -- the owner stands at the origin.
local function boundaryOf(domain: DomainSpec): DomainGeometry.Boundary
	return {
		Shape = domain.Shape,
		Center = Vector3.new(0, 0, -domain.CenterForward),
		Yaw = 0,
		Radius = domain.Radius,
		Height = domain.Height,
	}
end

function DomainTab.Boundary(
	scope: Scope,
	context: Fields.FormContext,
	visible: UsedAs<boolean>,
	tools: Tools
): ScrollingFrame
	local bind = binder(scope, context, tools)
	local notSphere = bind.When(function(domain)
		return domain.Shape ~= "Sphere"
	end)
	local isFixed = bind.When(function(domain)
		return domain.Anchor == "Fixed"
	end)
	local follows = bind.When(function(domain)
		return domain.Anchor == "FollowOwner"
	end)

	local sizeButtons = {}
	for _, step in SIZE_STEPS do
		table.insert(sizeButtons, {
			Text = step.Text,
			OnActivated = function()
				bind.EditDomain(function(domain)
					domain.Radius = math.clamp(step.Radius, DOMAIN_LIMITS.Radius.Min, DOMAIN_LIMITS.Radius.Max)
					domain.Height = math.clamp(step.Radius, DOMAIN_LIMITS.Height.Min, DOMAIN_LIMITS.Height.Max)
				end)
			end,
		})
	end

	return Fields.Page(scope, "BoundaryTab", visible, {
		bind.PageIssues("Boundary", 0),
		Fields.Section(scope, {
			Title = "SHAPE",
			Summary = bind.Summary(function(domain)
				return if domain.Shape == "Sphere"
					then `Sphere  R {domain.Radius}`
					else `{domain.Shape}  R {domain.Radius}  H {domain.Height}`
			end),
			LayoutOrder = 1,
			Build = function()
				return {
					bind.Choice("Shape", "Shape", SHAPE_OPTIONS, 1),
					Fields.ButtonRow(scope, context, {
						Label = "Size",
						Buttons = sizeButtons,
						Hint = "Sets the radius, and a cylinder or box's height with it: 16, 36, 60 or 100 studs.",
						LayoutOrder = 2,
					}),
					bind.Number("Radius", "Radius", "studs", { 1, 10 }, 0, 3),
					bind.Number("Height", "Height", "studs", { 1, 10 }, 0, 4, notSphere),
					Fields.Prose(
						scope,
						Copy.Domain.SphereHeight,
						5,
						bind.When(function(domain)
							return domain.Shape == "Sphere"
						end)
					),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "FOOTPRINT",
			Summary = bind.Summary(function(domain)
				return `{trim(domain.Radius * 2)} studs across`
			end),
			LayoutOrder = 2,
			Build = function()
				return {
					Fields.Fact(
						scope,
						"Across",
						bind.Summary(function(domain)
							local across = trim(domain.Radius * 2)
							return if domain.Shape == "Sphere"
								then `{across} studs, {across} tall`
								elseif
									domain.Shape == "Box"
								then `{across} x {across} studs, {trim(domain.Height)} tall`
								else `{across} studs, {trim(domain.Height)} tall`
						end),
						1
					),
					Fields.Fact(
						scope,
						"Clash reach",
						bind.Summary(function(domain)
							return `{trim(DomainGeometry.BoundingRadius(boundaryOf(domain)))} studs from the centre`
						end),
						2
					),
					Fields.Fact(
						scope,
						"The owner opens it",
						bind.Summary(function(domain)
							local depth = DomainGeometry.Depth(boundaryOf(domain), Vector3.zero)
							return if depth >= 0
								then `inside, {trim(depth)} studs from the edge`
								else `OUTSIDE, {trim(-depth)} studs past the edge`
						end),
						3
					),
					Fields.Prose(scope, Copy.Domain.ClashReach, 4),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "PLACEMENT",
			Summary = bind.Summary(function(domain)
				local anchor = if domain.Anchor == "Fixed" then "Fixed" else "Follows owner"
				return if domain.CenterForward ~= 0 then `{anchor}  ·  {domain.CenterForward} forward` else anchor
			end),
			LayoutOrder = 3,
			Build = function()
				return {
					bind.Choice("Anchor", "Anchor", ANCHOR_OPTIONS, 1),
					Fields.Prose(scope, Copy.Domain.FollowsOwner, 2, follows),
					bind.Number("Centre forward", "CenterForward", "studs", { 1, 10 }, 0, 3),
					Toggle(scope, {
						Label = "Show on my character",
						Hint = "Draws the realm's boundary where it would open from you, live -- only you see it.",
						HintVisible = context.Hints,
						Value = tools.ShowOnCharacter,
						LayoutOrder = 4,
						OnChanged = function(on: boolean)
							tools.ShowOnCharacter:set(on)
						end,
					}),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "CROSSING",
			Summary = bind.Summary(function(domain)
				local line = `in: {domain.EntryRule}  ·  out: {domain.ExitRule}`
				return if domain.BoundaryCollision and domain.Anchor == "Fixed" then `{line}  ·  walled` else line
			end),
			LayoutOrder = 4,
			Build = function()
				return {
					bind.Choice("Entry", "EntryRule", RULE_OPTIONS, 1),
					bind.Choice("Exit", "ExitRule", RULE_OPTIONS, 2),
					bind.Number("Entry grace", "EntryGraceSeconds", "seconds", { 0.1, 1 }, 2, 3),
					bind.Number("Exit linger", "ExitLingerSeconds", "seconds", { 0.1, 1 }, 2, 4),
					bind.Toggle("Physical wall", "BoundaryCollision", 5, isFixed),
					bind.Reading(
						bind.Summary(function(domain)
							if domain.BoundaryCollision and domain.Anchor == "Fixed" then
								return "Walled: a physical wall stops every body both ways, owner included -- the rules above only matter to a body already past it."
							end
							local into = if domain.EntryRule == "Barred"
								then "Anyone not inside when it is established is repelled at the edge."
								else "Anyone may walk in."
							local out = if domain.ExitRule == "Barred"
								then "Everyone inside at establishment is held -- except the owner."
								else "Anyone may walk out."
							return `{into} {out} (Enforced by the server, not a wall.)`
						end),
						6
					),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "SHOTS",
			Summary = bind.Summary(function(domain)
				return `in: {if domain.ProjectilesEnter then "pass" else "stop"}  ·  out: {if domain.ProjectilesLeave
					then "pass"
					else "stop"}`
			end),
			LayoutOrder = 5,
			Build = function()
				return {
					bind.Toggle("Shots may enter", "ProjectilesEnter", 1),
					bind.Toggle("Shots may leave", "ProjectilesLeave", 2),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "COLLAPSE",
			Summary = bind.Summary(function(domain)
				local parts = {}
				if domain.CancelOnOwnerHit then
					table.insert(parts, "owner hit")
				end
				if domain.CancelOnOwnerExit and domain.Anchor == "Fixed" then
					table.insert(parts, "owner leaves")
				end
				return if #parts > 0 then `on {table.concat(parts, ", ")}` else "only on time"
			end),
			LayoutOrder = 6,
			Build = function()
				return {
					bind.Toggle("Collapse if the owner is hit while unfurling", "CancelOnOwnerHit", 1),
					bind.Toggle("Collapse if the owner leaves", "CancelOnOwnerExit", 2, isFixed),
					Fields.Prose(scope, Copy.Domain.AlwaysCollapses, 3),
				}
			end,
		}),
	})
end

-- EFFECTS ----------------------------------------------------------------------------------------------------

function DomainTab.Effects(
	scope: Scope,
	context: Fields.FormContext,
	visible: UsedAs<boolean>,
	tools: Tools
): ScrollingFrame
	local bind = binder(scope, context, tools)

	local function effectSlot(index: number): { Instance }
		local function entryOf(domain: DomainSpec): any
			return domain.Effects[index]
		end
		local function effectIs(predicate: (DomainTypes.Effect) -> boolean): Fusion.Computed<boolean>
			return bind.When(function(domain)
				local effect = domain.Effects[index]
				return effect ~= nil and predicate(effect)
			end)
		end
		local function kindIs(kind: string): Fusion.Computed<boolean>
			return effectIs(function(effect)
				return effect.Kind == kind
			end)
		end
		local needsMove = effectIs(function(effect)
			-- A Strike may name a move too (blank is the realm's own strike), so it shows the field as well.
			return DomainTypes.EffectNeedsMove[effect.Kind] == true
				or DomainTypes.EffectMayUseOwnMove[effect.Kind] == true
		end)
		local isStrike = kindIs("Strike")
		local isShot = effectIs(function(effect)
			return effect.Kind == "Strike" or effect.Kind == "Volley"
		end)
		local targeted = effectIs(function(effect)
			return effect.Kind ~= "OwnerCast"
		end)
		local kindHint = bind.Summary(function(domain)
			local effect = domain.Effects[index]
			return if effect then Copy.Domain.EffectExplain[effect.Kind] or "" else ""
		end)
		local magnitudeRanges = {
			Hitstun = { Min = 0, Max = DomainConstants.MaxHitstunSeconds },
			Pull = { Min = 0, Max = DomainConstants.ImpulseMaxSpeed },
			Push = { Min = 0, Max = DomainConstants.ImpulseMaxSpeed },
		}

		return {
			bind.Choice("Kind", "Kind", EFFECT_OPTIONS, 1, nil, entryOf),
			bind.Reading(kindHint, 2),
			bind.MoveId(
				"Move",
				"MoveId",
				3,
				needsMove,
				entryOf,
				HINTS.EffectMoveId,
				"The realm's own strike",
				function(entry, domain)
					-- A Volley launches a projectile move; a realm never names another realm.
					local effect = if domain then domain.Effects[index] else nil
					if entry.Move.Domain ~= nil then
						return false
					end
					return effect == nil or effect.Kind ~= "Volley" or entry.Move.Projectile ~= nil
				end
			),
			-- Whose price a hit pays: the realm's own (Strike price, top of this page) or the named move's.
			Fields.Fact(
				scope,
				"Each hit costs",
				bind.Described(function(domain, move, moves)
					local effect = domain.Effects[index]
					if not effect then
						return ""
					end
					local power = if effect.Power ~= 1 then `  x{trim(effect.Power)} power` else ""
					if effect.Kind == "Strike" and effect.MoveId == "" then
						return `this realm's strike price: {PriceFields.Summary(move)}{power}`
					end
					local referenced = moves[effect.MoveId]
					if referenced == nil then
						return if effect.MoveId == "" then "pick a move" else `"{effect.MoveId}" -- not a known move`
					end
					return `{referenced.DisplayName}'s price: {PriceFields.Summary(referenced)}{power}`
				end),
				4,
				isShot
			),
			bind.Number("Every", "IntervalSeconds", "seconds", { 0.25, 1 }, 2, 5, nil, entryOf),
			bind.Number(
				"First after",
				"FirstDelaySeconds",
				"seconds once established",
				{ 0.25, 1 },
				2,
				6,
				nil,
				entryOf
			),
			Fields.Fact(
				scope,
				"Over a full hold",
				bind.Summary(function(domain)
					local effect = domain.Effects[index]
					if not effect then
						return ""
					end
					local pulses = DomainInsight.Pulses(effect, domain)
					return if pulses == 0
						then "never fires -- the first pulse is after the fold"
						else `fires {pulses} times, at {trim(effect.FirstDelaySeconds)}s then every {trim(
							effect.IntervalSeconds
						)}s`
				end),
				7
			),
			bind.Choice("Affects", "Affects", FILTER_OPTIONS, 8, targeted, entryOf),
			bind.Choice("Target types", "TargetTypes", TYPE_OPTIONS, 9, targeted, entryOf),
			bind.Number("Per pulse", "MaxPerPulse", "targets, nearest first", { 1, 4 }, 0, 10, targeted, entryOf),
			bind.Number(
				"Stun",
				"Magnitude",
				"seconds",
				{ 0.05, 0.25 },
				2,
				11,
				kindIs("Hitstun"),
				entryOf,
				magnitudeRanges.Hitstun
			),
			bind.Number("Posture", "Magnitude", "guard per pulse", { 1, 10 }, 0, 12, kindIs("GuardDrain"), entryOf),
			bind.Number(
				"Pull",
				"Magnitude",
				"studs/s",
				{ 1, 10 },
				0,
				13,
				kindIs("Pull"),
				entryOf,
				magnitudeRanges.Pull
			),
			bind.Number(
				"Push",
				"Magnitude",
				"studs/s",
				{ 1, 10 },
				0,
				14,
				kindIs("Push"),
				entryOf,
				magnitudeRanges.Push
			),
			bind.Choice("From", "Origin", ORIGIN_OPTIONS, 15, isShot, entryOf, HINTS.Origin),
			bind.Number("From distance", "OriginDistance", "studs", { 1, 5 }, 0, 16, isShot, entryOf),
			bind.Number(
				"Arrives in",
				"TravelSeconds",
				"seconds",
				{ 0.05, 0.25 },
				2,
				17,
				isStrike,
				entryOf,
				nil,
				HINTS.TravelSeconds
			),
			bind.Number("Strike size", "StrikeSize", "studs radius", { 0.1, 1 }, 1, 18, isStrike, entryOf),
			bind.Number("Power", "Power", "x the price", { 0.1, 0.5 }, 2, 19, isShot, entryOf, nil, HINTS.EffectPower),
			bind.Toggle("Parryable", "Parryable", 20, isStrike, entryOf, HINTS.Parryable),
		}
	end

	local kindOptions: { Option } = {}
	for _, kind in DomainTypes.EffectKinds do
		table.insert(kindOptions, { Value = kind, Text = Copy.Domain.EffectKindChips[kind] or kind })
	end

	local children: { Instance } = {
		bind.PageIssues("Effects", 0),
		Fields.Section(scope, {
			Title = "STRIKE PRICE",
			Summary = scope:Computed(function(use)
				return PriceFields.Summary(use(context.Draft))
			end),
			LayoutOrder = 1,
			Build = function()
				local fields: { Instance } = { Fields.Prose(scope, Copy.Domain.StrikePrice, 0) }
				for _, field in PriceFields.Cost(scope, context) do
					table.insert(fields, field)
				end
				-- After the cost's own orders (1..4).
				table.insert(fields, Fields.Pile(scope, 10, nil, PriceFields.Knockback(scope, context)))
				return fields
			end,
		}),
		Fields.Heading(scope, "EFFECTS", 2),
		Fields.Prose(
			scope,
			bind.Described(function(domain, _, moves)
				if #domain.Effects == 0 then
					return "None yet. An effect fires on a timer at the realm's members: pick a kind below to add one."
				end
				local demand = DomainInsight.ShotDemand(domain, moves)
				local shots = if demand > 0
					then `  ·  up to {trim(demand)} shots/s of the {DomainConstants.Strike.MaxShotsPerSecond}/s a realm may fire`
					else ""
				return `{#domain.Effects} of {DomainTypes.MaxEffects}{shots}.`
			end),
			3
		),
		Fields.ActionChips(scope, context, {
			Label = "Add",
			Options = kindOptions,
			Describe = Copy.Domain.EffectExplain,
			Hint = "Adds an effect of that kind at the end, with a starting magnitude that suits it.",
			LayoutOrder = 4,
			Visible = bind.When(function(domain)
				return #domain.Effects < DomainTypes.MaxEffects
			end),
			Apply = function(move, kind)
				local domain = move.Domain
				if domain and #domain.Effects < DomainTypes.MaxEffects then
					table.insert(domain.Effects, DomainInsight.NewEffect(kind))
				end
			end,
		}),
	}
	for _, slot in
		bind.Slots({
			Title = "EFFECT",
			Max = DomainTypes.MaxEffects,
			FirstOrder = 10,
			List = function(domain)
				return domain.Effects
			end,
			Describe = function(effect, domain, moves)
				return DomainInsight.DescribeEffect(effect, domain, moves)
			end,
			Build = effectSlot,
			EntryFields = DomainTypes.EffectFields,
		})
	do
		table.insert(children, slot)
	end
	return Fields.Page(scope, "EffectsTab", visible, children)
end

-- LAW --------------------------------------------------------------------------------------------------------

function DomainTab.Law(
	scope: Scope,
	context: Fields.FormContext,
	visible: UsedAs<boolean>,
	tools: Tools
): ScrollingFrame
	local bind = binder(scope, context, tools)

	local function ruleSlot(index: number): { Instance }
		local function entryOf(domain: DomainSpec): any
			return domain.Rules[index]
		end
		local function ruleIs(predicate: (DomainTypes.Rule) -> boolean): Fusion.Computed<boolean>
			return bind.When(function(domain)
				local rule = domain.Rules[index]
				return rule ~= nil and predicate(rule)
			end)
		end
		return {
			bind.Choice("Rule", "Kind", RULE_KIND_OPTIONS, 1, nil, entryOf, nil, true),
			bind.Reading(
				bind.Described(function(domain, _, moves)
					local rule = domain.Rules[index]
					return if rule then DomainInsight.DescribeRule(rule, moves) else ""
				end),
				2
			),
			bind.Number(
				"Multiplier",
				"Value",
				"x",
				{ 0.05, 0.25 },
				2,
				3,
				ruleIs(function(rule)
					return DomainTypes.ScaleRules[rule.Kind] == true
				end),
				entryOf,
				nil,
				HINTS.RuleValue
			),
			bind.MoveId(
				"Sealed move",
				"MoveId",
				4,
				ruleIs(function(rule)
					return rule.Kind == "SealMove"
				end),
				entryOf,
				HINTS.SealMoveId
			),
			Fields.Prose(
				scope,
				Copy.Domain.FlagRule,
				5,
				ruleIs(function(rule)
					return DomainTypes.ScaleRules[rule.Kind] ~= true and rule.Kind ~= "SealMove"
				end)
			),
			bind.Choice("Affects", "Affects", FILTER_OPTIONS, 6, nil, entryOf),
			bind.Choice("Target types", "TargetTypes", TYPE_OPTIONS, 7, nil, entryOf),
		}
	end

	local children: { Instance } = {
		bind.PageIssues("Law", 0),
		Fields.Section(scope, {
			Title = "UNDER THIS LAW",
			Summary = bind.Summary(function(domain)
				return if #domain.Rules == 0 then "no rules" else `{#domain.Rules} of {DomainTypes.MaxRules} rules`
			end),
			LayoutOrder = 1,
			Build = function()
				return {
					bind.Reading(
						bind.Described(function(domain, _, moves)
							local audiences = DomainInsight.Law(domain, moves)
							if #audiences == 0 then
								return if #domain.Rules == 0
									then "No law yet. A rule holds for as long as a body is under the realm: damage, defence, movement, cooldowns, seals. Pick a kind below to add one."
									else "The rules add up to nothing: every multiplier is x1."
							end
							local lines: { string } = {}
							for _, audience in audiences do
								table.insert(lines, `{audience.Name}: {table.concat(audience.Clauses, ", ")}`)
							end
							return table.concat(lines, "\n")
						end),
						1
					),
					Fields.Prose(scope, Copy.Domain.LawComposition, 2),
				}
			end,
		}),
		Fields.ActionChips(scope, context, {
			Label = "Add",
			Options = RULE_KIND_OPTIONS,
			Describe = Copy.Domain.RuleExplain,
			Hint = "Adds a rule of that kind on enemies, at the end. A multiplier starts at a value that does something.",
			LayoutOrder = 2,
			Visible = bind.When(function(domain)
				return #domain.Rules < DomainTypes.MaxRules
			end),
			Apply = function(move, kind)
				local domain = move.Domain
				if domain and #domain.Rules < DomainTypes.MaxRules then
					table.insert(domain.Rules, DomainInsight.NewRule(kind))
				end
			end,
		}),
	}
	for _, slot in
		bind.Slots({
			Title = "RULE",
			Max = DomainTypes.MaxRules,
			FirstOrder = 10,
			List = function(domain)
				return domain.Rules
			end,
			Describe = function(rule, _, moves)
				return DomainInsight.DescribeRule(rule, moves)
			end,
			Build = ruleSlot,
			EntryFields = DomainTypes.RuleFields,
		})
	do
		table.insert(children, slot)
	end
	return Fields.Page(scope, "LawTab", visible, children)
end

-- CLASH ------------------------------------------------------------------------------------------------------

-- The other realms the editor knows, by name, for MATCHUPS and a new override's opponent.
local function otherRealms(moves: DomainInsight.MovesById, ownId: string): { Move }
	local realms: { Move } = {}
	for id, candidate in moves do
		if id ~= ownId and candidate.Domain ~= nil then
			table.insert(realms, candidate)
		end
	end
	table.sort(realms, function(a: Move, b: Move): boolean
		return a.DisplayName < b.DisplayName
	end)
	return realms
end

function DomainTab.Clash(
	scope: Scope,
	context: Fields.FormContext,
	visible: UsedAs<boolean>,
	tools: Tools
): ScrollingFrame
	local bind = binder(scope, context, tools)
	local interacts = bind.When(function(domain)
		return domain.Interacts
	end)
	local clashHint = bind.Summary(function(domain)
		return Copy.Domain.ClashBehaviors[domain.ClashBehavior] or ""
	end)

	local function overrideSlot(index: number): { Instance }
		local function entryOf(domain: DomainSpec): any
			return domain.ClashOverrides[index]
		end
		local behaviorHint = bind.Summary(function(domain)
			local override = domain.ClashOverrides[index]
			return if override then Copy.Domain.ClashBehaviors[override.Behavior] or "" else ""
		end)
		return {
			bind.MoveId(
				"Against realm",
				"OpponentMoveId",
				1,
				nil,
				entryOf,
				HINTS.OpponentMoveId,
				"No realm picked",
				function(entry)
					return entry.Move.Domain ~= nil
				end
			),
			bind.Choice("Behaviour", "Behavior", CLASH_OPTIONS, 2, nil, entryOf, behaviorHint),
			-- What the override comes to, against that realm's own authored clash settings.
			bind.Reading(
				bind.Described(function(domain, move, moves)
					local override = domain.ClashOverrides[index]
					local opponent = if override then moves[override.OpponentMoveId] else nil
					local theirs = if opponent then opponent.Domain else nil
					if opponent == nil or theirs == nil then
						return ""
					end
					local matchup = DomainInsight.Matchup(move.MoveId, domain, opponent.MoveId, theirs)
					return `Opening into it: {matchup.MineOpensLater}.\nIt opening into this: {matchup.TheirsOpensLater}.`
				end),
				3
			),
		}
	end

	local children: { Instance } = {
		bind.PageIssues("Clash", 0),
		Fields.Section(scope, {
			Title = "CLASH",
			Summary = bind.Summary(function(domain)
				if not domain.Interacts then
					return "ignores other realms"
				end
				return `priority {domain.Priority}  ·  {domain.ClashBehavior}`
			end),
			LayoutOrder = 1,
			Build = function()
				return {
					bind.Toggle("Interacts with other realms", "Interacts", 1),
					bind.Number("Priority", "Priority", "", { 1, 10 }, 0, 2, interacts),
					bind.Choice("Against a weaker realm", "ClashBehavior", CLASH_OPTIONS, 3, interacts, nil, clashHint),
					bind.Choice("On a tie", "TieBreak", TIE_OPTIONS, 4, interacts),
					bind.Number(
						"Erode rate",
						"ErodeRate",
						"x",
						{ 0.1, 0.5 },
						2,
						5,
						bind.When(function(domain)
							-- Read whenever this realm may erode anyone: by default, or through an override.
							if not domain.Interacts then
								return false
							end
							if domain.ClashBehavior == "Erode" then
								return true
							end
							for _, override in domain.ClashOverrides do
								if override.Behavior == "Erode" then
									return true
								end
							end
							return false
						end)
					),
					bind.Number("Contest strength", "ContestScale", "of full", { 0.05, 0.25 }, 2, 6, interacts),
					Fields.Prose(scope, Copy.Domain.ClashOrder, 7, interacts),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "MATCHUPS",
			Summary = bind.Described(function(_, move, moves)
				local count = #otherRealms(moves, move.MoveId)
				return if count == 0 then "no other realms" else `{count} other realm{if count == 1 then "" else "s"}`
			end),
			LayoutOrder = 2,
			Build = function()
				return {
					bind.Reading(
						bind.Described(function(domain, move, moves)
							local realms = otherRealms(moves, move.MoveId)
							if #realms == 0 then
								return "No other realm exists yet -- author one and its matchup appears here."
							end
							local lines: { string } = {}
							for index, other in realms do
								if index > MATCHUP_ROWS then
									table.insert(lines, `... and {#realms - MATCHUP_ROWS} more.`)
									break
								end
								local theirs = other.Domain :: DomainSpec
								local matchup = DomainInsight.Matchup(move.MoveId, domain, other.MoveId, theirs)
								local priority = if theirs.Interacts
									then `priority {theirs.Priority}`
									else "ignores realms"
								table.insert(
									lines,
									`{other.DisplayName} ({priority})\n   opening into it: {matchup.MineOpensLater}\n   it opening into this: {matchup.TheirsOpensLater}`
								)
							end
							return table.concat(lines, "\n")
						end),
						1
					),
					Fields.Prose(scope, Copy.Domain.Matchups, 2),
				}
			end,
		}),
		Fields.Heading(scope, "OVERRIDES", 3, interacts),
		Fields.Prose(scope, Copy.Domain.Overrides, 4, interacts),
	}
	local slots = bind.Slots({
		Title = "OVERRIDE",
		Max = DomainTypes.MaxClashOverrides,
		FirstOrder = 10,
		List = function(domain)
			return domain.ClashOverrides
		end,
		Describe = function(override, _, moves)
			local opponent = moves[override.OpponentMoveId]
			local name = if opponent then opponent.DisplayName else override.OpponentMoveId
			return `vs {name}  ·  {override.Behavior}`
		end,
		Build = overrideSlot,
		EntryFields = DomainTypes.ClashOverrideFields,
	})
	table.insert(
		slots,
		Fields.ButtonRow(scope, context, {
			Label = "New override",
			LayoutOrder = DomainTypes.MaxClashOverrides + 20,
			Visible = bind.When(function(domain)
				return #domain.ClashOverrides < DomainTypes.MaxClashOverrides
			end),
			Buttons = {
				{
					Text = "Add",
					OnActivated = function()
						local moves = peek(tools.MovesById)
						bind.EditDomain(function(domain, move)
							if #domain.ClashOverrides >= DomainTypes.MaxClashOverrides then
								return
							end
							local override = DomainTypes.DefaultClashOverride()
							-- The first realm not yet answered, so the new override is valid as it lands; with none
							-- known, a placeholder the author replaces (Validate refuses a blank opponent).
							local answered: { [string]: boolean } = {}
							for _, existing in domain.ClashOverrides do
								answered[existing.OpponentMoveId] = true
							end
							override.OpponentMoveId = "opponent-move-id"
							for _, other in otherRealms(moves, move.MoveId) do
								if not answered[other.MoveId] then
									override.OpponentMoveId = other.MoveId
									break
								end
							end
							table.insert(domain.ClashOverrides, override)
						end)
					end,
				},
			},
			Hint = "Adds an override against the first realm this one does not answer yet.",
		})
	)
	-- The overrides only mean something while the realm interacts at all.
	table.insert(children, Fields.Pile(scope, 10, interacts, slots))
	return Fields.Page(scope, "ClashTab", visible, children)
end

return DomainTab
