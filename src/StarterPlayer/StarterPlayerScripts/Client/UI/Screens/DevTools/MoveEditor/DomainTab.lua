--!strict
--[[
	MoveEditor/DomainTab.lua

	Owns: the Domain tab -- authoring the optional MoveDefinition.Domain block that makes a move open a
	realm (Shared/Domain/DomainTypes.lua). The Move Editor's, not a separate editor's: a realm IS a move
	(DomainTypes' header), so everything a swing already says -- its clip, windup, cooldown, art binding
	and presentation -- is authored where it always is, and this tab is what the swing does not say.

	FIVE GROUPS, in the order an author builds a realm:
	    BASIC     name and description (the move's own, shown here too), the three phase lengths, the
	              cooldown (the move's), the Qi cost (the art binding's, when there is one) and upkeep, and
	              how many bodies it can govern
	    BOUNDARY  shape, size, anchor, the entry/exit rules, the wall, the projectile edge, and the two
	              owner-side cancel conditions
	    EFFECTS   up to DomainTypes.MaxEffects periodic effects, each a KIND of delivery through a system
	              that already exists, targeting a filter of the realm's members
	    COMBAT    up to DomainTypes.MaxRules continuous rules -- damage, defence, movement, cooldowns,
	              seals, parry/block/evade/escape -- each on a filter
	    CLASH     priority, the default behaviour toward a weaker realm, the tie-break, erosion, contest,
	              and per-opponent overrides

	THE LISTS ARE FIXED SLOTS, NOT A GROWING TREE. Every slot's fields are mounted once and shown while the
	slot exists (index <= #list) -- the same "every page mounted up front, Visible toggles" idiom the tabs
	themselves use, so adding an entry never rebuilds the page under the cursor. Add appends a default entry;
	each slot's Remove drops its own. Edits go through the context's one Edit like every other field.

	OPTIONAL BLOCK, behind one toggle, the ImpactTab convention: off is absent (nil), not zeroed; on seeds
	DomainTypes.Defaults() -- a working realm, never a zero-length one. Turning it on drops a grab
	(MoveRegistryManager.Validate refuses the pair). A Default (weapon) move cannot open a realm.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Move = MoveTypes.MoveDefinition
type DomainSpec = DomainTypes.DomainSpec

local LIMITS = Constants.MoveEditor.Limits
local DOMAIN_LIMITS = DomainTypes.Limits
local HINTS = Copy.Domain.Hints

local function options(values: { string }, labels: { [string]: string }?): { { Value: string, Text: string } }
	local result = {}
	for _, value in values do
		table.insert(result, { Value = value, Text = if labels and labels[value] then labels[value] else value })
	end
	return result
end

local SHAPE_OPTIONS = options(DomainTypes.Shapes)
local ANCHOR_OPTIONS = options(DomainTypes.Anchors, { Fixed = "Fixed", FollowOwner = "Follow owner" })
local RULE_OPTIONS = options(DomainTypes.BoundaryRules, { Open = "Open", Barred = "Barred" })
local FILTER_OPTIONS = options(DomainTypes.TargetFilters, Copy.Domain.TargetFilters)
local TYPE_OPTIONS =
	options(DomainTypes.TargetTypes, { Any = "Anyone", Players = "Players", NonPlayers = "Bots and dummies" })
local EFFECT_OPTIONS = options(DomainTypes.EffectKinds, Copy.Domain.EffectKinds)
local ORIGIN_OPTIONS =
	options(DomainTypes.StrikeOrigins, { Above = "Above", Center = "The centre", Owner = "The owner", Ring = "A ring" })
local RULE_KIND_OPTIONS = options(DomainTypes.RuleKinds, Copy.Domain.RuleKinds)
local CLASH_OPTIONS = options(DomainTypes.ClashBehaviors, Copy.Domain.ClashBehaviors)
local TIE_OPTIONS =
	options(DomainTypes.TieBreaks, { Contest = "Contest", Older = "Older realm holds", Newer = "Newer realm claims" })

local function domainOf(move: Move): DomainSpec?
	return move.Domain
end

-- A button that can be hidden (Components/Button has no Visible of its own -- Fields.Choice's reasoning).
local function actionButton(
	scope: Scope,
	text: string,
	layoutOrder: number,
	visible: UsedAs<boolean>,
	onActivated: () -> ()
): Frame
	return scope:New "Frame" {
		Name = `Action_{text}`,
		Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
		BackgroundTransparency = 1,
		Visible = visible,
		LayoutOrder = layoutOrder,
		[Fusion.Children] = Button(scope, {
			Text = text,
			Size = UDim2.fromScale(0.5, 1),
			OnActivated = onActivated,
		}),
	} :: Frame
end

local function DomainTab(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local isCustom = scope:Computed(function(use)
		return not use(context.IsDefault)
	end)
	local hasDomain = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and move.Domain ~= nil and not use(context.IsDefault)
	end)

	-- A Computed over the open realm, or false while there is none.
	local function whenDomain(predicate: (DomainSpec, Move) -> boolean): Fusion.Computed<boolean>
		return scope:Computed(function(use)
			local move = use(context.Draft)
			if move == nil or use(context.IsDefault) then
				return false
			end
			local domain = move.Domain
			return domain ~= nil and predicate(domain, move)
		end)
	end

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	local children: { Instance } = {}
	local function add(child: Instance): ()
		table.insert(children, child)
	end

	-- Top-level number / toggle / choice fields on the spec itself.
	local function specNumber(
		label: string,
		field: string,
		unit: string,
		steps: { number },
		decimals: number,
		shown: UsedAs<boolean>?
	): ()
		add(Fields.Number(scope, context, {
			Label = label,
			Unit = unit,
			Range = DOMAIN_LIMITS[field],
			Steps = steps,
			Decimals = decimals,
			Hint = HINTS[field],
			Visible = shown or hasDomain,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local domain = domainOf(move)
				return if domain then (domain :: any)[field] else DOMAIN_LIMITS[field].Min
			end,
			Set = function(move, value)
				local domain = domainOf(move)
				if domain then
					(domain :: any)[field] = value
				end
			end,
		}))
	end
	local function specToggle(label: string, field: string, shown: UsedAs<boolean>?): ()
		add(Fields.Toggle(scope, context, {
			Label = label,
			Hint = HINTS[field],
			Visible = shown or hasDomain,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local domain = domainOf(move)
				return domain ~= nil and (domain :: any)[field] == true
			end,
			Set = function(move, value)
				local domain = domainOf(move)
				if domain then
					(domain :: any)[field] = value
				end
			end,
		}))
	end
	local function specChoice(
		label: string,
		field: string,
		choices: { { Value: string, Text: string } },
		shown: UsedAs<boolean>?
	): ()
		add(Fields.Choice(scope, context, {
			Label = label,
			Options = choices,
			Visible = shown or hasDomain,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local domain = domainOf(move)
				return if domain then (domain :: any)[field] else choices[1].Value
			end,
			Set = function(move, value)
				local domain = domainOf(move)
				if domain then
					(domain :: any)[field] = value
				end
			end,
		}))
		local hint = HINTS[field]
		if hint then
			add(Fields.Prose(scope, hint, nextOrder(), shown or hasDomain))
		end
	end

	-- THE TOGGLE -----------------------------------------------------------------------------------------------
	add(Fields.Prose(scope, Copy.Domain.Intro, nextOrder(), isCustom))
	add(Fields.Prose(scope, Copy.Domain.DefaultMove, nextOrder(), context.IsDefault))
	add(Fields.Toggle(scope, context, {
		Label = "This move opens a realm",
		LayoutOrder = nextOrder(),
		Visible = isCustom,
		Get = function(move)
			return move.Domain ~= nil
		end,
		Set = function(move, on)
			if on then
				move.Domain = DomainTypes.Defaults()
				-- MoveRegistryManager.Validate refuses a grab on a realm move.
				move.Grab = nil
			else
				move.Domain = nil
			end
		end,
	}))

	-- BASIC ----------------------------------------------------------------------------------------------------
	add(Fields.Heading(scope, "BASIC", nextOrder(), hasDomain))
	add(Fields.Text(scope, context, {
		Label = "Name",
		MaxLength = LIMITS.DisplayNameLength,
		Visible = hasDomain,
		LayoutOrder = nextOrder(),
		Get = function(move)
			return move.DisplayName
		end,
		Set = function(move, value)
			move.DisplayName = value
		end,
	}))
	add(Fields.Text(scope, context, {
		Label = "Description",
		MaxLength = LIMITS.DescriptionLength,
		Multiline = true,
		Visible = hasDomain,
		LayoutOrder = nextOrder(),
		Get = function(move)
			return move.Description
		end,
		Set = function(move, value)
			move.Description = value
		end,
	}))
	specNumber("Activation", "ActivationSeconds", "seconds", { 0.1, 0.5 }, 2)
	specNumber("Duration", "ActiveSeconds", "seconds", { 0.5, 5 }, 1)
	specNumber("Fold", "EndSeconds", "seconds", { 0.1, 0.5 }, 2)
	add(Fields.Number(scope, context, {
		Label = "Cooldown",
		Unit = "seconds",
		Range = LIMITS.CooldownSeconds,
		Steps = { 1, 5 },
		Decimals = 1,
		Hint = Copy.Hints.Cooldown,
		Visible = hasDomain,
		LayoutOrder = nextOrder(),
		Get = function(move)
			return move.Cooldown
		end,
		Set = function(move, value)
			move.Cooldown = value
		end,
	}))
	local hasArt = whenDomain(function(_, move)
		return move.Art ~= nil
	end)
	local noArt = whenDomain(function(_, move)
		return move.Art == nil
	end)
	add(Fields.Number(scope, context, {
		Label = "Qi cost",
		Unit = "Qi per cast",
		Range = ArtConstants.Limits.QiCost,
		Steps = { 5, 25 },
		Decimals = 0,
		Visible = hasArt,
		LayoutOrder = nextOrder(),
		Get = function(move)
			return if move.Art then move.Art.QiCost else 0
		end,
		Set = function(move, value)
			if move.Art then
				move.Art.QiCost = value
			end
		end,
	}))
	add(Fields.Prose(scope, Copy.Domain.QiCostNotArt, nextOrder(), noArt))
	specNumber("Qi upkeep", "UpkeepQiPerSecond", "Qi per second", { 1, 5 }, 1)
	specNumber("Max targets", "MaxTargets", "bodies", { 1, 4 }, 0)

	-- BOUNDARY -------------------------------------------------------------------------------------------------
	local notSphere = whenDomain(function(domain)
		return domain.Shape ~= "Sphere"
	end)
	local isFixed = whenDomain(function(domain)
		return domain.Anchor == "Fixed"
	end)
	add(Fields.Heading(scope, "BOUNDARY", nextOrder(), hasDomain))
	specChoice("Shape", "Shape", SHAPE_OPTIONS)
	specNumber("Radius", "Radius", "studs", { 1, 10 }, 0)
	specNumber("Height", "Height", "studs", { 1, 10 }, 0, notSphere)
	specChoice("Anchor", "Anchor", ANCHOR_OPTIONS)
	specNumber("Centre forward", "CenterForward", "studs", { 1, 10 }, 0)
	specChoice("Entry", "EntryRule", RULE_OPTIONS)
	specChoice("Exit", "ExitRule", RULE_OPTIONS)
	specNumber("Entry grace", "EntryGraceSeconds", "seconds", { 0.1, 1 }, 2)
	specNumber("Exit linger", "ExitLingerSeconds", "seconds", { 0.1, 1 }, 2)
	specToggle("Physical wall", "BoundaryCollision", isFixed)
	specToggle("Shots may enter", "ProjectilesEnter")
	specToggle("Shots may leave", "ProjectilesLeave")
	specToggle("Collapse if the owner is hit while unfurling", "CancelOnOwnerHit")
	specToggle("Collapse if the owner leaves", "CancelOnOwnerExit", isFixed)

	-- EFFECTS --------------------------------------------------------------------------------------------------
	add(Fields.Heading(scope, "EFFECTS", nextOrder(), hasDomain))
	for index = 1, DomainTypes.MaxEffects do
		local slotExists = whenDomain(function(domain)
			return index <= #domain.Effects
		end)
		local function effectIs(predicate: (DomainTypes.Effect) -> boolean): Fusion.Computed<boolean>
			return whenDomain(function(domain)
				local effect = domain.Effects[index]
				return effect ~= nil and predicate(effect)
			end)
		end
		local function effectField(move: Move): DomainTypes.Effect?
			local domain = domainOf(move)
			return if domain then domain.Effects[index] else nil
		end

		local heading, shown = Fields.Fold(scope, `EFFECT {index}`, nextOrder(), slotExists)
		add(heading)
		local function within(extra: Fusion.Computed<boolean>): Fusion.Computed<boolean>
			return scope:Computed(function(use)
				return use(shown) and use(extra)
			end)
		end
		local needsMove = within(effectIs(function(effect)
			return DomainTypes.EffectNeedsMove[effect.Kind] == true
		end))
		local isStrike = within(effectIs(function(effect)
			return effect.Kind == "Strike"
		end))
		local isShot = within(effectIs(function(effect)
			return effect.Kind == "Strike" or effect.Kind == "Volley"
		end))
		local isKind = function(kind: string): Fusion.Computed<boolean>
			return within(effectIs(function(effect)
				return effect.Kind == kind
			end))
		end
		local targeted = within(effectIs(function(effect)
			return effect.Kind ~= "OwnerCast"
		end))

		add(Fields.Choice(scope, context, {
			Label = "Kind",
			Options = EFFECT_OPTIONS,
			Visible = shown,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local effect = effectField(move)
				return if effect then effect.Kind else "Strike"
			end,
			Set = function(move, value)
				local effect = effectField(move)
				if effect then
					effect.Kind = value :: any
				end
			end,
		}))
		add(Fields.Text(scope, context, {
			Label = "Move id",
			Placeholder = "the id of the move to deliver",
			MaxLength = DomainTypes.MoveIdLength,
			Hint = HINTS.EffectMoveId,
			Visible = needsMove,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local effect = effectField(move)
				return if effect then effect.MoveId else ""
			end,
			Set = function(move, value)
				local effect = effectField(move)
				if effect then
					effect.MoveId = value
				end
			end,
		}))

		local function effectNumber(
			label: string,
			field: string,
			unit: string,
			steps: { number },
			decimals: number,
			shownWhen: Fusion.Computed<boolean>,
			range: { Min: number, Max: number }?,
			hint: string?
		): ()
			add(Fields.Number(scope, context, {
				Label = label,
				Unit = unit,
				Range = range or DOMAIN_LIMITS[field],
				Steps = steps,
				Decimals = decimals,
				Hint = hint,
				Visible = shownWhen,
				LayoutOrder = nextOrder(),
				Get = function(move)
					local effect = effectField(move)
					return if effect then (effect :: any)[field] else (range or DOMAIN_LIMITS[field]).Min
				end,
				Set = function(move, value)
					local effect = effectField(move)
					if effect then
						(effect :: any)[field] = value
					end
				end,
			}))
		end
		local function effectChoice(
			label: string,
			field: string,
			choices: { { Value: string, Text: string } },
			shownWhen: Fusion.Computed<boolean>
		): ()
			add(Fields.Choice(scope, context, {
				Label = label,
				Options = choices,
				Visible = shownWhen,
				LayoutOrder = nextOrder(),
				Get = function(move)
					local effect = effectField(move)
					return if effect then (effect :: any)[field] else choices[1].Value
				end,
				Set = function(move, value)
					local effect = effectField(move)
					if effect then
						(effect :: any)[field] = value
					end
				end,
			}))
		end

		effectNumber("Every", "IntervalSeconds", "seconds", { 0.25, 1 }, 2, shown)
		effectNumber("First after", "FirstDelaySeconds", "seconds once established", { 0.25, 1 }, 2, shown)
		effectChoice("Affects", "Affects", FILTER_OPTIONS, targeted)
		effectChoice("Target types", "TargetTypes", TYPE_OPTIONS, targeted)
		effectNumber("Per pulse", "MaxPerPulse", "targets, nearest first", { 1, 4 }, 0, targeted)
		effectNumber(
			"Stun",
			"Magnitude",
			"seconds",
			{ 0.05, 0.25 },
			2,
			isKind("Hitstun"),
			{ Min = 0, Max = DomainConstants.MaxHitstunSeconds }
		)
		effectNumber("Posture", "Magnitude", "guard per pulse", { 1, 10 }, 0, isKind("GuardDrain"))
		effectNumber(
			"Pull",
			"Magnitude",
			"studs/s",
			{ 1, 10 },
			0,
			isKind("Pull"),
			{ Min = 0, Max = DomainConstants.ImpulseMaxSpeed }
		)
		effectNumber(
			"Push",
			"Magnitude",
			"studs/s",
			{ 1, 10 },
			0,
			isKind("Push"),
			{ Min = 0, Max = DomainConstants.ImpulseMaxSpeed }
		)
		effectChoice("From", "Origin", ORIGIN_OPTIONS, isShot)
		effectNumber("From distance", "OriginDistance", "studs", { 1, 5 }, 0, isShot, nil, HINTS.Origin)
		effectNumber("Arrives in", "TravelSeconds", "seconds", { 0.05, 0.25 }, 2, isStrike, nil, HINTS.TravelSeconds)
		effectNumber("Strike size", "StrikeSize", "studs radius", { 0.1, 1 }, 1, isStrike)
		add(Fields.Toggle(scope, context, {
			Label = "Parryable",
			Hint = HINTS.Parryable,
			Visible = isStrike,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local effect = effectField(move)
				return effect ~= nil and effect.Parryable
			end,
			Set = function(move, value)
				local effect = effectField(move)
				if effect then
					effect.Parryable = value
				end
			end,
		}))
		add(actionButton(scope, `Remove effect {index}`, nextOrder(), shown, function()
			context.Edit(function(move)
				local domain = domainOf(move)
				if domain and domain.Effects[index] then
					table.remove(domain.Effects, index)
				end
			end)
		end))
	end
	add(actionButton(
		scope,
		"Add effect",
		nextOrder(),
		whenDomain(function(domain)
			return #domain.Effects < DomainTypes.MaxEffects
		end),
		function()
			context.Edit(function(move)
				local domain = domainOf(move)
				if domain and #domain.Effects < DomainTypes.MaxEffects then
					table.insert(domain.Effects, DomainTypes.DefaultEffect())
				end
			end)
		end
	))

	-- COMBAT (rules) -------------------------------------------------------------------------------------------
	add(Fields.Heading(scope, "COMBAT", nextOrder(), hasDomain))
	for index = 1, DomainTypes.MaxRules do
		local slotExists = whenDomain(function(domain)
			return index <= #domain.Rules
		end)
		local function ruleField(move: Move): DomainTypes.Rule?
			local domain = domainOf(move)
			return if domain then domain.Rules[index] else nil
		end
		local heading, shown = Fields.Fold(scope, `RULE {index}`, nextOrder(), slotExists)
		add(heading)
		local function ruleIs(predicate: (DomainTypes.Rule) -> boolean): Fusion.Computed<boolean>
			return scope:Computed(function(use)
				local move = use(context.Draft)
				local domain = if move then move.Domain else nil
				local rule = if domain then domain.Rules[index] else nil
				return use(shown) and rule ~= nil and predicate(rule)
			end)
		end

		add(Fields.Choice(scope, context, {
			Label = "Rule",
			Options = RULE_KIND_OPTIONS,
			Visible = shown,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local rule = ruleField(move)
				return if rule then rule.Kind else "DamageTaken"
			end,
			Set = function(move, value)
				local rule = ruleField(move)
				if rule then
					rule.Kind = value :: any
				end
			end,
		}))
		add(Fields.Number(scope, context, {
			Label = "Multiplier",
			Unit = "x",
			Range = DOMAIN_LIMITS.Value,
			Steps = { 0.05, 0.25 },
			Decimals = 2,
			Hint = HINTS.RuleValue,
			Visible = ruleIs(function(rule)
				return DomainTypes.ScaleRules[rule.Kind] == true
			end),
			LayoutOrder = nextOrder(),
			Get = function(move)
				local rule = ruleField(move)
				return if rule then rule.Value else 1
			end,
			Set = function(move, value)
				local rule = ruleField(move)
				if rule then
					rule.Value = value
				end
			end,
		}))
		add(Fields.Text(scope, context, {
			Label = "Sealed move id",
			MaxLength = DomainTypes.MoveIdLength,
			Hint = HINTS.SealMoveId,
			Visible = ruleIs(function(rule)
				return rule.Kind == "SealMove"
			end),
			LayoutOrder = nextOrder(),
			Get = function(move)
				local rule = ruleField(move)
				return if rule then rule.MoveId else ""
			end,
			Set = function(move, value)
				local rule = ruleField(move)
				if rule then
					rule.MoveId = value
				end
			end,
		}))
		add(Fields.Choice(scope, context, {
			Label = "Affects",
			Options = FILTER_OPTIONS,
			Visible = shown,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local rule = ruleField(move)
				return if rule then rule.Affects else "Enemies"
			end,
			Set = function(move, value)
				local rule = ruleField(move)
				if rule then
					rule.Affects = value :: any
				end
			end,
		}))
		add(Fields.Choice(scope, context, {
			Label = "Target types",
			Options = TYPE_OPTIONS,
			Visible = shown,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local rule = ruleField(move)
				return if rule then rule.TargetTypes else "Any"
			end,
			Set = function(move, value)
				local rule = ruleField(move)
				if rule then
					rule.TargetTypes = value :: any
				end
			end,
		}))
		add(actionButton(scope, `Remove rule {index}`, nextOrder(), shown, function()
			context.Edit(function(move)
				local domain = domainOf(move)
				if domain and domain.Rules[index] then
					table.remove(domain.Rules, index)
				end
			end)
		end))
	end
	add(actionButton(
		scope,
		"Add rule",
		nextOrder(),
		whenDomain(function(domain)
			return #domain.Rules < DomainTypes.MaxRules
		end),
		function()
			context.Edit(function(move)
				local domain = domainOf(move)
				if domain and #domain.Rules < DomainTypes.MaxRules then
					table.insert(domain.Rules, DomainTypes.DefaultRule())
				end
			end)
		end
	))

	-- CLASH ----------------------------------------------------------------------------------------------------
	add(Fields.Heading(scope, "CLASH", nextOrder(), hasDomain))
	specNumber("Priority", "Priority", "", { 1, 10 }, 0)
	specChoice("Against a weaker realm", "ClashBehavior", CLASH_OPTIONS)
	specChoice("On a tie", "TieBreak", TIE_OPTIONS)
	specNumber("Erode rate", "ErodeRate", "x", { 0.1, 0.5 }, 2)
	specNumber("Contest strength", "ContestScale", "of full", { 0.05, 0.25 }, 2)
	specToggle("Interacts with other realms", "Interacts")
	for index = 1, DomainTypes.MaxClashOverrides do
		local slotExists = whenDomain(function(domain)
			return index <= #domain.ClashOverrides
		end)
		local function overrideField(move: Move): DomainTypes.ClashOverride?
			local domain = domainOf(move)
			return if domain then domain.ClashOverrides[index] else nil
		end
		add(Fields.Heading(scope, `OVERRIDE {index}`, nextOrder(), slotExists))
		add(Fields.Text(scope, context, {
			Label = "Against realm move id",
			MaxLength = DomainTypes.MoveIdLength,
			Hint = HINTS.OpponentMoveId,
			Visible = slotExists,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local override = overrideField(move)
				return if override then override.OpponentMoveId else ""
			end,
			Set = function(move, value)
				local override = overrideField(move)
				if override then
					override.OpponentMoveId = value
				end
			end,
		}))
		add(Fields.Choice(scope, context, {
			Label = "Behaviour",
			Options = CLASH_OPTIONS,
			Visible = slotExists,
			LayoutOrder = nextOrder(),
			Get = function(move)
				local override = overrideField(move)
				return if override then override.Behavior else "Suppress"
			end,
			Set = function(move, value)
				local override = overrideField(move)
				if override then
					override.Behavior = value :: any
				end
			end,
		}))
		add(actionButton(scope, `Remove override {index}`, nextOrder(), slotExists, function()
			context.Edit(function(move)
				local domain = domainOf(move)
				if domain and domain.ClashOverrides[index] then
					table.remove(domain.ClashOverrides, index)
				end
			end)
		end))
	end
	add(actionButton(
		scope,
		"Add clash override",
		nextOrder(),
		whenDomain(function(domain)
			return #domain.ClashOverrides < DomainTypes.MaxClashOverrides
		end),
		function()
			context.Edit(function(move)
				local domain = domainOf(move)
				if domain and #domain.ClashOverrides < DomainTypes.MaxClashOverrides then
					local override = DomainTypes.DefaultClashOverride()
					-- An override needs an opponent to validate; a placeholder the author then replaces.
					override.OpponentMoveId = "opponent-move-id"
					table.insert(domain.ClashOverrides, override)
				end
			end)
		end
	))

	-- PRESENTATION ---------------------------------------------------------------------------------------------
	add(Fields.Heading(scope, "PRESENTATION", nextOrder(), hasDomain))
	add(Fields.Prose(scope, Copy.Domain.Presentation, nextOrder(), hasDomain))

	return Fields.Page(scope, "DomainTab", visible, children)
end

return DomainTab
