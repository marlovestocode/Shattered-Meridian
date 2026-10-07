--!strict
--[[
	MoveEditor/DomainTab.lua

	Owns: the five pages a DOMAIN EXPANSION gets instead of Hitbox and Impact -- authoring the
	MoveDefinition.Domain block that makes a move open a realm (Shared/Domain/DomainTypes.lua):

	    Realm     the realm's own clock (unfurl, hold, fold), its cost (Qi, upkeep) and how many it governs
	    Boundary  its shape and size, where it sits, who may cross it and how, what collapses it
	    Effects   STRIKE PRICE -- what the realm's OWN strike costs a body -- then up to DomainTypes
	              .MaxEffects periodic effects, each a kind of delivery through a system that already exists
	    Law       up to DomainTypes.MaxRules continuous rules on a filter of its members
	    Clash     priority, behaviour toward a weaker realm, the tie-break, erosion, contest, overrides

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

	THE LISTS ARE FIXED SLOTS, BUILT ON DEMAND. Each slot is a Fields.Section shown while the slot exists
	(index <= #list) and built the first time it is shown open, so a realm with two effects has built two
	effects' fields, not six (the old single Domain tab mounted all ~300 slot fields up front). Built once, a
	slot is kept and only toggles, so adding an entry never rebuilds the page under the cursor. Add appends a
	default entry; each slot's Remove drops its own. Edits go through the context's one Edit like every other
	field.

	Choosing the move type is the type bar's (init.lua): it seeds DomainTypes.Defaults() -- a working realm,
	never a zero-length one -- and drops any grab or projectile block (Validate refuses a grab on a realm).
	These pages are only offered while the block exists, so nothing here creates or removes it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)
local PriceFields = require(script.Parent.PriceFields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Move = MoveTypes.MoveDefinition
type DomainSpec = DomainTypes.DomainSpec
type Option = Fields.Option

local DOMAIN_LIMITS = DomainTypes.Limits
local HINTS = Copy.Domain.Hints

local options = Fields.OptionsOf

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

-- The open move's realm. Every page is offered only while there is one (init.lua), but a field still reads
-- through this so a stale frame between a type change and the tab hand-over never indexes nil.
local function domainOf(move: Move): DomainSpec?
	return move.Domain
end

-- One page's field builders, bound to its scope and context.
local function binder(scope: Scope, context: Fields.FormContext)
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
			if not hintText then
				return Fields.Choice(scope, context, {
					Label = label,
					Options = choices,
					Visible = shown,
					LayoutOrder = order,
					Get = get,
					Set = set,
				})
			end
			-- A dropdown carries no hint of its own: stack one under it.
			return Fields.Pile(scope, order, shown, {
				Fields.Choice(scope, context, {
					Label = label,
					Options = choices,
					LayoutOrder = 1,
					Get = get,
					Set = set,
				}),
				Fields.Prose(scope, hintText, 2),
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
		placeholder: string?
	): Frame
		return Fields.Text(scope, context, {
			Label = label,
			Placeholder = placeholder,
			MaxLength = DomainTypes.MoveIdLength,
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

	-- A half-width action button.
	function bind.Action(text: string, order: number, shown: UsedAs<boolean>?, mutate: (DomainSpec) -> ()): Frame
		return scope:New "Frame" {
			Name = `Action_{text}`,
			Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
			BackgroundTransparency = 1,
			Visible = shown,
			LayoutOrder = order,
			[Fusion.Children] = Button(scope, {
				Text = text,
				Size = UDim2.fromScale(0.5, 1),
				OnActivated = function()
					context.Edit(function(move)
						local domain = domainOf(move)
						if domain then
							mutate(domain)
						end
					end)
				end,
			}),
		} :: Frame
	end

	-- A run of fixed slots over one of the realm's lists (see this file's header): a section per slot, shown
	-- while that slot exists, and the Add button under them.
	function bind.Slots(spec: {
		Title: string,
		Max: number,
		FirstOrder: number,
		List: (DomainSpec) -> { any },
		Describe: (any) -> string,
		Build: (index: number) -> { Instance },
		AddText: string,
		NewEntry: () -> any,
	}): { Instance }
		local built: { Instance } = {}
		for index = 1, spec.Max do
			table.insert(
				built,
				Fields.Section(scope, {
					Title = `{spec.Title} {index}`,
					Summary = bind.Summary(function(domain)
						local entry = spec.List(domain)[index]
						return if entry then spec.Describe(entry) else ""
					end),
					LayoutOrder = spec.FirstOrder + index,
					Visible = bind.When(function(domain)
						return index <= #spec.List(domain)
					end),
					Build = function()
						return spec.Build(index)
					end,
				})
			)
		end
		table.insert(
			built,
			bind.Action(
				spec.AddText,
				spec.FirstOrder + spec.Max + 1,
				bind.When(function(domain)
					return #spec.List(domain) < spec.Max
				end),
				function(domain)
					local list = spec.List(domain)
					if #list < spec.Max then
						table.insert(list, spec.NewEntry())
					end
				end
			)
		)
		return built
	end

	return bind
end

local DomainTab = {}

-- REALM ------------------------------------------------------------------------------------------------------

function DomainTab.Realm(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local bind = binder(scope, context)
	local hasArt = bind.When(function(_, move)
		return move.Art ~= nil
	end)
	local noArt = bind.When(function(_, move)
		return move.Art == nil
	end)

	return Fields.Page(scope, "RealmTab", visible, {
		Fields.Prose(scope, Copy.Domain.Realm, 1),
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
			LayoutOrder = 2,
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
			LayoutOrder = 3,
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
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "GOVERNS",
			Summary = bind.Summary(function(domain)
				return `up to {domain.MaxTargets} bodies`
			end),
			LayoutOrder = 4,
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

export type WorldTools = {
	ShowOnCharacter: Fusion.Value<boolean>,
}

function DomainTab.Boundary(
	scope: Scope,
	context: Fields.FormContext,
	visible: UsedAs<boolean>,
	world: WorldTools
): ScrollingFrame
	local bind = binder(scope, context)
	local notSphere = bind.When(function(domain)
		return domain.Shape ~= "Sphere"
	end)
	local isFixed = bind.When(function(domain)
		return domain.Anchor == "Fixed"
	end)

	return Fields.Page(scope, "BoundaryTab", visible, {
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
					bind.Number("Radius", "Radius", "studs", { 1, 10 }, 0, 2),
					bind.Number("Height", "Height", "studs", { 1, 10 }, 0, 3, notSphere),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "PLACEMENT",
			Summary = bind.Summary(function(domain)
				local anchor = if domain.Anchor == "Fixed" then "Fixed" else "Follows owner"
				return if domain.CenterForward ~= 0 then `{anchor}  ·  {domain.CenterForward} forward` else anchor
			end),
			LayoutOrder = 2,
			Build = function()
				return {
					bind.Choice("Anchor", "Anchor", ANCHOR_OPTIONS, 1),
					bind.Number("Centre forward", "CenterForward", "studs", { 1, 10 }, 0, 2),
					Toggle(scope, {
						Label = "Show on my character",
						Hint = "Draws the realm's boundary where it would open from you, live -- only you see it.",
						Value = world.ShowOnCharacter,
						LayoutOrder = 3,
						OnChanged = function(on: boolean)
							world.ShowOnCharacter:set(on)
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
			LayoutOrder = 3,
			Build = function()
				return {
					bind.Choice("Entry", "EntryRule", RULE_OPTIONS, 1),
					bind.Choice("Exit", "ExitRule", RULE_OPTIONS, 2),
					bind.Number("Entry grace", "EntryGraceSeconds", "seconds", { 0.1, 1 }, 2, 3),
					bind.Number("Exit linger", "ExitLingerSeconds", "seconds", { 0.1, 1 }, 2, 4),
					bind.Toggle("Physical wall", "BoundaryCollision", 5, isFixed),
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
			LayoutOrder = 4,
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
			LayoutOrder = 5,
			Build = function()
				return {
					bind.Toggle("Collapse if the owner is hit while unfurling", "CancelOnOwnerHit", 1),
					bind.Toggle("Collapse if the owner leaves", "CancelOnOwnerExit", 2, isFixed),
				}
			end,
		}),
	})
end

-- EFFECTS ----------------------------------------------------------------------------------------------------

local function describeEffect(effect: DomainTypes.Effect): string
	local kind = Copy.Domain.EffectKindChips[effect.Kind] or effect.Kind
	local who = if effect.Kind == "OwnerCast"
		then ""
		else `  ·  {Copy.Domain.TargetFilters[effect.Affects] or effect.Affects}`
	local what = if effect.Kind == "Strike" and effect.MoveId == "" then "own strike" else effect.MoveId
	local named = if what ~= "" then `{kind} ({what})` else kind
	return `{named}  ·  every {effect.IntervalSeconds}s{who}`
end

function DomainTab.Effects(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local bind = binder(scope, context)

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
			return if effect then Copy.Domain.EffectKinds[effect.Kind] or "" else ""
		end)
		local magnitudeRanges = {
			Hitstun = { Min = 0, Max = DomainConstants.MaxHitstunSeconds },
			Pull = { Min = 0, Max = DomainConstants.ImpulseMaxSpeed },
			Push = { Min = 0, Max = DomainConstants.ImpulseMaxSpeed },
		}

		return {
			bind.Choice("Kind", "Kind", EFFECT_OPTIONS, 1, nil, entryOf, kindHint),
			bind.MoveId(
				"Move id",
				"MoveId",
				2,
				needsMove,
				entryOf,
				HINTS.EffectMoveId,
				"blank: the realm's own strike"
			),
			bind.Number("Every", "IntervalSeconds", "seconds", { 0.25, 1 }, 2, 3, nil, entryOf),
			bind.Number(
				"First after",
				"FirstDelaySeconds",
				"seconds once established",
				{ 0.25, 1 },
				2,
				4,
				nil,
				entryOf
			),
			bind.Choice("Affects", "Affects", FILTER_OPTIONS, 5, targeted, entryOf),
			bind.Choice("Target types", "TargetTypes", TYPE_OPTIONS, 6, targeted, entryOf),
			bind.Number("Per pulse", "MaxPerPulse", "targets, nearest first", { 1, 4 }, 0, 7, targeted, entryOf),
			bind.Number(
				"Stun",
				"Magnitude",
				"seconds",
				{ 0.05, 0.25 },
				2,
				8,
				kindIs("Hitstun"),
				entryOf,
				magnitudeRanges.Hitstun
			),
			bind.Number("Posture", "Magnitude", "guard per pulse", { 1, 10 }, 0, 9, kindIs("GuardDrain"), entryOf),
			bind.Number(
				"Pull",
				"Magnitude",
				"studs/s",
				{ 1, 10 },
				0,
				10,
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
				11,
				kindIs("Push"),
				entryOf,
				magnitudeRanges.Push
			),
			bind.Choice("From", "Origin", ORIGIN_OPTIONS, 12, isShot, entryOf, HINTS.Origin),
			bind.Number("From distance", "OriginDistance", "studs", { 1, 5 }, 0, 13, isShot, entryOf),
			bind.Number(
				"Arrives in",
				"TravelSeconds",
				"seconds",
				{ 0.05, 0.25 },
				2,
				14,
				isStrike,
				entryOf,
				nil,
				HINTS.TravelSeconds
			),
			bind.Number("Strike size", "StrikeSize", "studs radius", { 0.1, 1 }, 1, 15, isStrike, entryOf),
			bind.Number("Power", "Power", "x the price", { 0.1, 0.5 }, 2, 16, isShot, entryOf, nil, HINTS.EffectPower),
			bind.Toggle("Parryable", "Parryable", 17, isStrike, entryOf, HINTS.Parryable),
			bind.Action(`Remove effect {index}`, 18, nil, function(domain)
				if domain.Effects[index] then
					table.remove(domain.Effects, index)
				end
			end),
		}
	end

	local children: { Instance } = {
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
			bind.Summary(function(domain)
				return if #domain.Effects == 0
					then "None yet. An effect fires on a timer at the realm's members: a strike, a volley, a stun, a pull ..."
					else `{#domain.Effects} of {DomainTypes.MaxEffects}.`
			end),
			3
		),
	}
	for _, slot in
		bind.Slots({
			Title = "EFFECT",
			Max = DomainTypes.MaxEffects,
			FirstOrder = 10,
			List = function(domain)
				return domain.Effects
			end,
			Describe = describeEffect,
			Build = effectSlot,
			AddText = "Add effect",
			NewEntry = DomainTypes.DefaultEffect,
		})
	do
		table.insert(children, slot)
	end
	return Fields.Page(scope, "EffectsTab", visible, children)
end

-- LAW --------------------------------------------------------------------------------------------------------

local function describeRule(rule: DomainTypes.Rule): string
	local kind = Copy.Domain.RuleKinds[rule.Kind] or rule.Kind
	local value = if DomainTypes.ScaleRules[rule.Kind]
		then ` x{rule.Value}`
		elseif rule.Kind == "SealMove" and rule.MoveId ~= "" then ` ({rule.MoveId})`
		else ""
	return `{kind}{value}  ·  {Copy.Domain.TargetFilters[rule.Affects] or rule.Affects}`
end

function DomainTab.Law(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local bind = binder(scope, context)

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
			bind.Number(
				"Multiplier",
				"Value",
				"x",
				{ 0.05, 0.25 },
				2,
				2,
				ruleIs(function(rule)
					return DomainTypes.ScaleRules[rule.Kind] == true
				end),
				entryOf,
				nil,
				HINTS.RuleValue
			),
			bind.MoveId(
				"Sealed move id",
				"MoveId",
				3,
				ruleIs(function(rule)
					return rule.Kind == "SealMove"
				end),
				entryOf,
				HINTS.SealMoveId
			),
			bind.Choice("Affects", "Affects", FILTER_OPTIONS, 4, nil, entryOf),
			bind.Choice("Target types", "TargetTypes", TYPE_OPTIONS, 5, nil, entryOf),
			bind.Action(`Remove rule {index}`, 6, nil, function(domain)
				if domain.Rules[index] then
					table.remove(domain.Rules, index)
				end
			end),
		}
	end

	local children: { Instance } = {
		Fields.Prose(
			scope,
			bind.Summary(function(domain)
				return if #domain.Rules == 0
					then "No law yet. A rule holds for as long as a body is under the realm: damage, defence, movement, cooldowns, seals."
					else `{#domain.Rules} of {DomainTypes.MaxRules} rules.`
			end),
			1
		),
	}
	for _, slot in
		bind.Slots({
			Title = "RULE",
			Max = DomainTypes.MaxRules,
			FirstOrder = 10,
			List = function(domain)
				return domain.Rules
			end,
			Describe = describeRule,
			Build = ruleSlot,
			AddText = "Add rule",
			NewEntry = DomainTypes.DefaultRule,
		})
	do
		table.insert(children, slot)
	end
	return Fields.Page(scope, "LawTab", visible, children)
end

-- CLASH ------------------------------------------------------------------------------------------------------

function DomainTab.Clash(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local bind = binder(scope, context)
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
			bind.MoveId("Against realm move id", "OpponentMoveId", 1, nil, entryOf, HINTS.OpponentMoveId),
			bind.Choice("Behaviour", "Behavior", CLASH_OPTIONS, 2, nil, entryOf, behaviorHint),
			bind.Action(`Remove override {index}`, 3, nil, function(domain)
				if domain.ClashOverrides[index] then
					table.remove(domain.ClashOverrides, index)
				end
			end),
		}
	end

	local children: { Instance } = {
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
							return domain.Interacts and domain.ClashBehavior == "Erode"
						end)
					),
					bind.Number("Contest strength", "ContestScale", "of full", { 0.05, 0.25 }, 2, 6, interacts),
				}
			end,
		}),
		Fields.Heading(scope, "OVERRIDES", 2, interacts),
		Fields.Prose(scope, Copy.Domain.Overrides, 3, interacts),
	}
	local slots = bind.Slots({
		Title = "OVERRIDE",
		Max = DomainTypes.MaxClashOverrides,
		FirstOrder = 10,
		List = function(domain)
			return domain.ClashOverrides
		end,
		Describe = function(override)
			local opponent = if override.OpponentMoveId ~= "" then override.OpponentMoveId else "?"
			return `vs {opponent}  ·  {override.Behavior}`
		end,
		Build = overrideSlot,
		AddText = "Add clash override",
		NewEntry = function()
			local override = DomainTypes.DefaultClashOverride()
			-- An override needs an opponent to validate; a placeholder the author then replaces.
			override.OpponentMoveId = "opponent-move-id"
			return override
		end,
	})
	-- The overrides only mean something while the realm interacts at all.
	table.insert(children, Fields.Pile(scope, 10, interacts, slots))
	return Fields.Page(scope, "ClashTab", visible, children)
end

return DomainTab
