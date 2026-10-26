--!strict
--[[
	MoveEditor/DomainInsight.lua

	Owns: what the Realm tab (DomainTab.lua) TELLS an author about a realm, as pure functions over a draft --
	its lifecycle laid end to end, how often each effect fires, what its law adds up to for each kind of
	body, how it meets every other realm, and the checks that find a realm that will not do what it says.
	Plus the two edits the tab offers that are more than one field: the archetype starting points, and
	moving / duplicating a list entry. No Fusion and no Instances, so every answer is a spec.

	EVERY ANSWER IS THE RUNTIME'S OWN, NEVER A SECOND MODEL OF IT:
	  * The law is composed by DomainRules.Apply -- the function DomainSystem folds rules with -- over the
	    same filter semantics as Allegiance.Matches/MatchesType (an ally is only ever a player sharing a
	    Team; a bot or dummy is never anyone's ally). Scales multiply, flags OR, seals union.
	  * A matchup is DomainClash.Resolve called twice -- once with each realm as the one that opened later --
	    over participants built exactly as DomainSystem.participantOf builds them.
	  * Pulse counts follow DomainSystem's clock: an effect's first pulse is FirstDelaySeconds after the
	    realm is ESTABLISHED, then every IntervalSeconds, and effects stop when the realm starts to fold.
	  * Upkeep is drained only while Active (DomainSystem.upkeep), so its total is rate x ActiveSeconds.
	  * The cancel window is DomainConstants.Cancel.WindowFraction of ActivationSeconds + ActiveSeconds,
	    measured from the moment the realm opens (DomainSystem's cancelDelay).
	What a check cannot know (who will stand inside, an opponent's ping) it does not pretend to: a shot rate
	is "with every slot filled", and a matchup is the arbitration only, not who stands in the overlap.

	SEVERITIES. An Error is something Save will refuse (DomainTypes.Validate's own refusals, caught while the
	author is still typing). A Warning is a setting that saves but will not do what it reads as at runtime
	(an effect that never fires, a move the catalogue cannot resolve, a value the runtime caps). A Note is a
	setting that is legal and works, but has no effect in this combination.

	Does not own: the schema or its validation (DomainTypes), any runtime behaviour, or drawing anything.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DomainClash = require(ReplicatedStorage.Shared.Domain.DomainClash)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainGeometry = require(ReplicatedStorage.Shared.Domain.DomainGeometry)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

type Move = MoveTypes.MoveDefinition
type DomainSpec = DomainTypes.DomainSpec

local DomainInsight = {}

-- Moves by id, for the checks and descriptions that follow a reference. nil (or empty) is "the editor has
-- not heard from the server yet", and every check that needs it is skipped rather than failed.
export type MovesById = { [string]: Move }

function DomainInsight.MovesById(entries: { { Move: Move } }): MovesById
	local map: MovesById = {}
	for _, entry in entries do
		map[entry.Move.MoveId] = entry.Move
	end
	return map
end

local function trim(value: number): string
	-- Two decimals at most, no trailing zeros: 1.5, 0.35, 12.
	local text = string.format("%.2f", value)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end
DomainInsight.Trim = trim

local function nameOf(moves: MovesById?, id: string): string
	local found = if moves then moves[id] else nil
	return if found then `{found.DisplayName}` else id
end

-- Lifecycle -------------------------------------------------------------------------------------------------

export type Timing = {
	WindupSeconds: number,
	Cooldown: number,
}

export type Lifecycle = {
	-- The cast's windup: the realm opens the moment it ends.
	Windup: number,
	Unfurl: number,
	Held: number,
	Fold: number,
	-- Unfurl + Held: how long the realm stands with any meaning (the cancel window's base).
	Standing: number,
	-- Windup through the end of the fold, from the press.
	Total: number,
	-- Seconds after the realm opens that its owner may end it by pressing the move again.
	CancelAfter: number,
	Cooldown: number,
	-- The Qi the cast costs (an art's QiCost; 0 for a move with no art binding), and the upkeep's total.
	QiCost: number,
	UpkeepTotal: number,
	-- Whether Windup/Cooldown are the server's effective numbers (the clip's) rather than the authored ones.
	Effective: boolean,
}

-- `effective` is the server entry's EffectiveTiming (a clip can move the windup); nil uses the authored one.
function DomainInsight.Lifecycle(move: Move, effective: Timing?): Lifecycle?
	local domain = move.Domain
	if domain == nil then
		return nil
	end
	local windup = if effective then effective.WindupSeconds else move.WindupSeconds
	local standing = domain.ActivationSeconds + domain.ActiveSeconds
	return {
		Windup = windup,
		Unfurl = domain.ActivationSeconds,
		Held = domain.ActiveSeconds,
		Fold = domain.EndSeconds,
		Standing = standing,
		Total = windup + DomainTypes.TotalSeconds(domain),
		CancelAfter = DomainConstants.Cancel.WindowFraction * standing,
		Cooldown = if effective then effective.Cooldown else move.Cooldown,
		QiCost = if move.Art then move.Art.QiCost else 0,
		UpkeepTotal = domain.UpkeepQiPerSecond * domain.ActiveSeconds,
		Effective = effective ~= nil,
	}
end

-- How many times `effect` fires over a realm that holds its whole ActiveSeconds (an early collapse fires
-- fewer). 0 when its first pulse would land after the fold has begun.
function DomainInsight.Pulses(effect: DomainTypes.Effect, domain: DomainSpec): number
	local window = domain.ActiveSeconds - effect.FirstDelaySeconds
	if window < 0 then
		return 0
	end
	return math.floor(window / effect.IntervalSeconds + 1e-6) + 1
end

-- The shots one pulse of a Strike or Volley may launch per target: 1 for a Strike, the referenced move's
-- first wave for a Volley (nil when that move is not known, or is not a projectile -- then it is a Strike).
local function shotsPerTarget(effect: DomainTypes.Effect, moves: MovesById?): number
	if effect.Kind ~= "Volley" then
		return 1
	end
	local referenced = if moves then moves[effect.MoveId] else nil
	local projectile = if referenced then referenced.Projectile else nil
	return if projectile then ProjectileTypes.ShotCount(projectile) else 1
end

-- The realm's demand on its shot budget with every target slot filled, in shots per second, across all of
-- its Strike and Volley effects -- against DomainConstants.Strike.MaxShotsPerSecond, past which pulses are
-- skipped (nearest bodies first, so the farthest are spared).
function DomainInsight.ShotDemand(domain: DomainSpec, moves: MovesById?): number
	local total = 0
	for _, effect in domain.Effects do
		if effect.Kind == "Strike" or effect.Kind == "Volley" then
			local targets = math.min(effect.MaxPerPulse, domain.MaxTargets)
			total += targets * shotsPerTarget(effect, moves) / effect.IntervalSeconds
		end
	end
	return total
end

-- One effect, in a line: what it is, how often, at whom, and how many times it lands over the hold.
function DomainInsight.DescribeEffect(effect: DomainTypes.Effect, domain: DomainSpec, moves: MovesById?): string
	local kind = effect.Kind
	local what: string
	if kind == "Strike" then
		what = if effect.MoveId == "" then "Own strike" else `Strike: {nameOf(moves, effect.MoveId)}`
		if effect.Power ~= 1 then
			what ..= ` x{trim(effect.Power)}`
		end
	elseif kind == "Volley" then
		what = `Volley: {if effect.MoveId == "" then "?" else nameOf(moves, effect.MoveId)}`
		if effect.Power ~= 1 then
			what ..= ` x{trim(effect.Power)}`
		end
	elseif kind == "OwnerCast" then
		what = `Owner casts {if effect.MoveId == "" then "?" else nameOf(moves, effect.MoveId)}`
	elseif kind == "Hitstun" then
		what = `Stun {trim(math.min(effect.Magnitude, DomainConstants.MaxHitstunSeconds))}s`
	elseif kind == "GuardDrain" then
		what = `Drain {trim(effect.Magnitude)} posture`
	else
		what = `{kind} {trim(math.min(effect.Magnitude, DomainConstants.ImpulseMaxSpeed))} studs/s`
	end
	local pulses = DomainInsight.Pulses(effect, domain)
	local rhythm = if pulses == 0 then "never fires" else `every {trim(effect.IntervalSeconds)}s, x{pulses}`
	return `{what}  ·  {rhythm}`
end

-- The law ---------------------------------------------------------------------------------------------------

-- Who a filter reaches, as the three roles a body can stand in relative to the owner. A bot or dummy is
-- never an ally (Allegiance.AreAllies: allies are players sharing a Team), so Ally is a player-only role.
local ROLE_MATCH: { [string]: { [string]: boolean } } = {
	Everyone = { Owner = true, Ally = true, Enemy = true },
	EveryoneButOwner = { Ally = true, Enemy = true },
	Owner = { Owner = true },
	OwnerAndAllies = { Owner = true, Ally = true },
	Allies = { Ally = true },
	Enemies = { Enemy = true },
}
DomainInsight.RoleMatch = ROLE_MATCH

local function typeMatches(targetType: string, isPlayer: boolean): boolean
	if targetType == "Any" then
		return true
	end
	return if targetType == "Players" then isPlayer else not isPlayer
end

local SCALE_TEXT: { [string]: string } = {
	DamageDealt = "deal %sx damage",
	DamageTaken = "take %sx damage",
	GuardDamageTaken = "take %sx posture damage",
	HitstunTaken = "stay stunned %sx as long",
	MoveSpeed = "move at %sx speed",
	Cooldown = "wait %sx as long on cooldowns",
}
local SCALE_ORDER = { "DamageDealt", "DamageTaken", "GuardDamageTaken", "HitstunTaken", "MoveSpeed", "Cooldown" }
local FLAG_TEXT: { { Flag: string, Text: string } } = {
	{ Flag = "Rooted", Text = "are rooted in place" },
	{ Flag = "NoBlock", Text = "cannot block" },
	{ Flag = "NoParry", Text = "cannot parry" },
	{ Flag = "NoEvade", Text = "cannot evade" },
	{ Flag = "NoParkour", Text = "lose escape mobility" },
	{ Flag = "SealArts", Text = "cannot cast arts" },
	{ Flag = "SealProjectiles", Text = "cannot throw projectile moves" },
	{ Flag = "SealDomains", Text = "cannot open realms" },
}

-- The clauses one composed RuleSet amounts to, in reading order. Empty for a set that changes nothing.
function DomainInsight.DescribeRuleSet(set: DomainRules.RuleSet, moves: MovesById?): { string }
	local clauses: { string } = {}
	local rooted = bit32.band(set.Flags, DomainRules.FlagBits.Rooted) ~= 0
	for _, kind in SCALE_ORDER do
		local value = (set :: any)[kind] :: number
		if math.abs(value - 1) > 1e-4 and not (kind == "MoveSpeed" and rooted) then
			table.insert(clauses, string.format(SCALE_TEXT[kind], trim(value)))
		end
	end
	for _, entry in FLAG_TEXT do
		if bit32.band(set.Flags, DomainRules.FlagBits[entry.Flag]) ~= 0 then
			table.insert(clauses, entry.Text)
		end
	end
	local sealed: { string } = {}
	for id in set.SealedMoves do
		table.insert(sealed, nameOf(moves, id))
	end
	table.sort(sealed)
	if #sealed > 0 then
		table.insert(clauses, `cannot throw {table.concat(sealed, ", ")}`)
	end
	return clauses
end

export type Audience = {
	-- "Enemies", "Enemy players", "Enemy bots", "Allies", "The owner".
	Name: string,
	Clauses: { string },
}

-- What the realm's whole law does to each kind of body under it, uncontested -- composed by the runtime's
-- own DomainRules.Apply. An audience whose set changes nothing is left out. Enemies split into players and
-- bots only when a rule's TargetTypes makes them differ. The owner is read as a player.
function DomainInsight.Law(domain: DomainSpec, moves: MovesById?): { Audience }
	local function compose(role: string, isPlayer: boolean): DomainRules.RuleSet
		local set = DomainRules.Empty()
		for _, rule in domain.Rules do
			if ROLE_MATCH[rule.Affects][role] and typeMatches(rule.TargetTypes, isPlayer) then
				DomainRules.Apply(set, rule.Kind, rule.Value, rule.MoveId, 1)
			end
		end
		return set
	end
	local audiences: { Audience } = {}
	local function add(name: string, set: DomainRules.RuleSet)
		local clauses = DomainInsight.DescribeRuleSet(set, moves)
		if #clauses > 0 then
			table.insert(audiences, { Name = name, Clauses = clauses })
		end
	end
	local enemyPlayers = DomainInsight.DescribeRuleSet(compose("Enemy", true), moves)
	local enemyBots = DomainInsight.DescribeRuleSet(compose("Enemy", false), moves)
	if table.concat(enemyPlayers, "|") == table.concat(enemyBots, "|") then
		add("Enemies", compose("Enemy", true))
	else
		add("Enemy players", compose("Enemy", true))
		add("Enemy bots", compose("Enemy", false))
	end
	add("Allies", compose("Ally", true))
	add("The owner", compose("Owner", true))
	return audiences
end

-- One rule, read as who it touches and what it does to them ("Enemies: take 1.5x damage").
function DomainInsight.DescribeRule(rule: DomainTypes.Rule, moves: MovesById?): string
	local set = DomainRules.Empty()
	DomainRules.Apply(set, rule.Kind, rule.Value, rule.MoveId, 1)
	local clauses = DomainInsight.DescribeRuleSet(set, moves)
	local who = ({
		Enemies = "Enemies",
		Allies = "Allies",
		Owner = "The owner",
		OwnerAndAllies = "The owner and allies",
		EveryoneButOwner = "Everyone but the owner",
		Everyone = "Everyone",
	} :: { [string]: string })[rule.Affects] or rule.Affects
	if rule.TargetTypes == "Players" then
		who ..= " (players)"
	elseif rule.TargetTypes == "NonPlayers" then
		who ..= " (bots)"
	end
	if #clauses == 0 then
		if rule.Kind == "SealMove" then
			return `{who}: no move picked to seal`
		end
		return `{who}: x1 -- changes nothing`
	end
	return `{who}: {table.concat(clauses, ", ")}`
end

-- Clash -----------------------------------------------------------------------------------------------------

local function participant(id: string, moveId: string, domain: DomainSpec, openedAt: number): DomainClash.Participant
	-- DomainSystem.participantOf's construction, field for field.
	local overrides: { [string]: string } = {}
	for _, override in domain.ClashOverrides do
		overrides[override.OpponentMoveId] = override.Behavior
	end
	return {
		Id = id,
		MoveId = moveId,
		Priority = domain.Priority,
		Behavior = domain.ClashBehavior,
		Overrides = overrides,
		TieBreak = domain.TieBreak,
		Interacts = domain.Interacts,
		OpenedAt = openedAt,
	}
end

-- One outcome, read from "my" side.
local function describeOutcome(outcome: DomainClash.Outcome, mine: DomainSpec, theirs: DomainSpec): string
	local behavior = outcome.Behavior
	if behavior == "Coexist" then
		return "Coexist: both hold, and a body in both answers to both"
	elseif behavior == "Contest" then
		return `Contest: neither wins; yours holds at {math.floor(mine.ContestScale * 100 + 0.5)}%, theirs at {math.floor(
			theirs.ContestScale * 100 + 0.5
		)}%`
	end
	local iWin = outcome.Winner == "mine"
	local winner = if iWin then "yours" else "theirs"
	local loser = if iWin then "theirs" else "yours"
	local winnerSpec = if iWin then mine else theirs
	if behavior == "Suppress" then
		return `{string.upper(string.sub(winner, 1, 1))}{string.sub(winner, 2)} suppresses {loser} in the overlap`
	elseif behavior == "Erode" then
		return `{string.upper(string.sub(winner, 1, 1))}{string.sub(winner, 2)} suppresses {loser} and wears {trim(
			winnerSpec.ErodeRate
		)}s off it per second`
	elseif behavior == "Dominate" then
		return `{string.upper(string.sub(loser, 1, 1))}{string.sub(loser, 2)} collapses`
	end
	return `Both collapse ({winner} shatters itself to break {loser})`
end

export type Matchup = {
	-- When their realm is already standing and mine opens into it, and the other way round.
	MineOpensLater: string,
	TheirsOpensLater: string,
}

-- How this realm meets another, both ways round, through DomainClash.Resolve itself.
function DomainInsight.Matchup(myMoveId: string, mine: DomainSpec, theirMoveId: string, theirs: DomainSpec): Matchup
	local function resolve(myOpen: number, theirOpen: number): string
		local outcome = DomainClash.Resolve(
			participant("mine", myMoveId, mine, myOpen),
			participant("theirs", theirMoveId, theirs, theirOpen)
		)
		return describeOutcome(outcome, mine, theirs)
	end
	return {
		MineOpensLater = resolve(1, 0),
		TheirsOpensLater = resolve(0, 1),
	}
end

-- Checks ----------------------------------------------------------------------------------------------------

export type Severity = "Error" | "Warning" | "Note"

export type Diagnostic = {
	Severity: Severity,
	-- The editor page that holds the field: a Realm page ("Realm", "Boundary", "Effects", "Law", "Clash") or
	-- a top-level tab ("Presentation", "Timing").
	Page: string,
	Text: string,
}

local SEVERITY_RANK: { [string]: number } = { Error = 1, Warning = 2, Note = 3 }

-- Every check the realm fails, errors first. See this file's header for what each severity means.
function DomainInsight.Diagnostics(move: Move, moves: MovesById?): { Diagnostic }
	local domain = move.Domain
	if domain == nil then
		return {}
	end
	local found: { Diagnostic } = {}
	local function add(severity: Severity, page: string, text: string)
		table.insert(found, { Severity = severity, Page = page, Text = text })
	end
	local known = moves ~= nil and next(moves) ~= nil
	local function lookup(id: string): Move?
		return if moves then moves[id] else nil
	end

	-- The realm as a whole.
	if #domain.Effects == 0 and #domain.Rules == 0 then
		add("Warning", "Effects", "The realm has no effects and no law -- it opens, and does nothing to anyone.")
	end
	if domain.EntryGraceSeconds >= domain.ActiveSeconds and #domain.Effects > 0 then
		add(
			"Warning",
			"Boundary",
			`Entry grace ({trim(domain.EntryGraceSeconds)}s) outlasts the hold ({trim(domain.ActiveSeconds)}s): a newcomer is never targeted by an effect.`
		)
	end
	local demand = DomainInsight.ShotDemand(domain, moves)
	local budget = DomainConstants.Strike.MaxShotsPerSecond
	if demand > budget then
		add(
			"Warning",
			"Effects",
			`With every slot filled the strikes ask for {trim(demand)} shots/s; a realm may fire {budget}/s, so pulses are skipped (the farthest bodies first).`
		)
	end
	if move.Cooldown < DomainTypes.TotalSeconds(domain) then
		add(
			"Note",
			"Timing",
			`The cooldown ({trim(move.Cooldown)}s) ends before the realm does ({trim(DomainTypes.TotalSeconds(domain))}s): a second cast still waits for the first realm to end.`
		)
	end

	-- Boundary.
	local follows = domain.Anchor == "FollowOwner"
	if follows and domain.BoundaryCollision then
		add("Note", "Boundary", "Physical wall is on, but a realm that follows its owner is never walled.")
	end
	if follows and domain.CancelOnOwnerExit then
		add(
			"Note",
			"Boundary",
			"'Collapse if the owner leaves' is on, but a realm that follows its owner cannot be left."
		)
	end
	if domain.BoundaryCollision and not follows and (domain.EntryRule == "Open" or domain.ExitRule == "Open") then
		add("Note", "Boundary", "The physical wall stops every body both ways, whatever Entry and Exit say.")
	end
	local ownerInside = DomainGeometry.Contains({
		Shape = domain.Shape,
		Center = Vector3.new(0, 0, -domain.CenterForward),
		Yaw = 0,
		Radius = domain.Radius,
		Height = domain.Height,
	}, Vector3.zero)
	if not ownerInside then
		if domain.CancelOnOwnerExit and not follows then
			add(
				"Warning",
				"Boundary",
				"The centre is so far forward that the owner opens the realm standing outside it -- with 'Collapse if the owner leaves' on, it ends as soon as it is established."
			)
		else
			add("Note", "Boundary", "The owner opens the realm standing outside it (Centre forward is past the edge).")
		end
	end

	-- Effects.
	local maxHitstun = DomainConstants.MaxHitstunSeconds
	for index, effect in domain.Effects do
		local label = `Effect {index}`
		local kind = effect.Kind
		if DomainTypes.EffectNeedsMove[kind] then
			if effect.MoveId == "" then
				add("Error", "Effects", `{label} ({kind}) names no move to deliver -- Save will refuse it.`)
			elseif effect.MoveId == move.MoveId then
				add("Error", "Effects", `{label} delivers this realm's own move -- it would re-open itself.`)
			end
		end
		if effect.MoveId ~= "" and effect.MoveId ~= move.MoveId and known then
			local referenced = lookup(effect.MoveId)
			if referenced == nil then
				add(
					"Warning",
					"Effects",
					`{label} names "{effect.MoveId}", which no longer exists -- the realm skips it.`
				)
			elseif kind == "Volley" and referenced.Projectile == nil then
				add(
					"Warning",
					"Effects",
					`{label} volleys {referenced.DisplayName}, which is not a projectile move -- it is delivered as one strike instead.`
				)
			elseif kind == "OwnerCast" and referenced.Domain ~= nil then
				add(
					"Warning",
					"Effects",
					`{label} has the owner cast {referenced.DisplayName}, another realm -- refused every time while this one holds.`
				)
			end
		end
		if DomainInsight.Pulses(effect, domain) == 0 then
			add(
				"Warning",
				"Effects",
				`{label} never fires: its first pulse ({trim(effect.FirstDelaySeconds)}s) comes after the hold ends ({trim(
					domain.ActiveSeconds
				)}s).`
			)
		end
		if kind == "Hitstun" and effect.Magnitude > maxHitstun then
			add(
				"Warning",
				"Effects",
				`{label} stuns for {trim(effect.Magnitude)}s, but one pulse is capped at {trim(maxHitstun)}s.`
			)
		end
		if
			(kind == "Hitstun" or kind == "GuardDrain" or kind == "Pull" or kind == "Push")
			and effect.Magnitude <= 0
		then
			add("Warning", "Effects", `{label} has a magnitude of 0 -- it reaches its targets and does nothing.`)
		end
		if DomainTypes.EffectUsesPower[kind] and effect.Power <= 0 then
			add("Warning", "Effects", `{label} has Power 0 -- its hits land for nothing.`)
		end
		if (kind == "Strike" or kind == "Volley") and effect.Affects == "Owner" then
			add("Warning", "Effects", `{label} targets only the owner, and a realm's shots never hit their own owner.`)
		end
		if kind ~= "OwnerCast" and effect.Affects == "Allies" and effect.TargetTypes == "NonPlayers" then
			add(
				"Warning",
				"Effects",
				`{label} targets allied bots -- a bot is never anyone's ally, so it reaches nobody.`
			)
		end
		if kind ~= "OwnerCast" and effect.MaxPerPulse > domain.MaxTargets then
			add(
				"Note",
				"Effects",
				`{label} may reach {effect.MaxPerPulse} per pulse, but the realm governs at most {domain.MaxTargets}.`
			)
		end
	end
	if #domain.Effects >= DomainTypes.MaxEffects then
		add("Note", "Effects", `All {DomainTypes.MaxEffects} effect slots are used.`)
	end

	-- Law.
	for index, rule in domain.Rules do
		local label = `Rule {index}`
		if rule.Kind == "SealMove" then
			if rule.MoveId == "" then
				add("Error", "Law", `{label} seals a move but names none -- Save will refuse it.`)
			elseif known and lookup(rule.MoveId) == nil then
				add("Warning", "Law", `{label} seals "{rule.MoveId}", which no longer exists.`)
			end
		elseif DomainTypes.ScaleRules[rule.Kind] and math.abs(rule.Value - 1) < 1e-4 then
			add("Warning", "Law", `{label} multiplies by 1 -- it changes nothing.`)
		end
		if rule.Affects == "Allies" and rule.TargetTypes == "NonPlayers" then
			add("Warning", "Law", `{label} binds allied bots -- a bot is never anyone's ally, so it binds nobody.`)
		end
	end
	if #domain.Rules >= DomainTypes.MaxRules then
		add("Note", "Law", `All {DomainTypes.MaxRules} rule slots are used.`)
	end

	-- Clash.
	local seen: { [string]: boolean } = {}
	for index, override in domain.ClashOverrides do
		local label = `Override {index}`
		local id = override.OpponentMoveId
		if id == "" then
			add("Error", "Clash", `{label} names no opposing realm -- Save will refuse it.`)
			continue
		end
		if seen[id] then
			add(
				"Warning",
				"Clash",
				`{label} repeats an opponent an earlier override already answers -- only the first is read.`
			)
		end
		seen[id] = true
		if known then
			local opponent = lookup(id)
			if opponent == nil then
				add("Warning", "Clash", `{label} answers "{id}", which no longer exists.`)
			elseif opponent.Domain == nil then
				add(
					"Warning",
					"Clash",
					`{label} answers {opponent.DisplayName}, which is not a realm -- it is never consulted.`
				)
			end
		end
		if override.Behavior == domain.ClashBehavior then
			add("Note", "Clash", `{label} repeats the default behaviour ({override.Behavior}) -- it changes nothing.`)
		end
	end
	if not domain.Interacts and #domain.ClashOverrides > 0 then
		add("Note", "Clash", "The realm ignores other realms, so its overrides are never read.")
	end

	-- Presentation: the realm's four moments (MovePresentationTypes), all optional.
	local presentation = move.Presentation
	local styled = false
	if presentation then
		for _, moment in { "DomainOpen", "DomainActive", "DomainPulse", "DomainClose" } do
			if presentation[moment] ~= nil then
				styled = true
			end
		end
	end
	if not styled then
		add(
			"Note",
			"Presentation",
			"None of the four Realm moments is styled -- it looks and sounds like every default realm."
		)
	end

	table.sort(found, function(a: Diagnostic, b: Diagnostic): boolean
		return SEVERITY_RANK[a.Severity] < SEVERITY_RANK[b.Severity]
	end)
	return found
end

-- "2 errors · 1 warning · 3 notes", or "" for none.
function DomainInsight.Tally(found: { Diagnostic }): string
	local counts = { Error = 0, Warning = 0, Note = 0 }
	for _, diagnostic in found do
		counts[diagnostic.Severity] += 1
	end
	local parts: { string } = {}
	local function part(count: number, one: string)
		if count > 0 then
			table.insert(parts, `{count} {one}{if count == 1 then "" else "s"}`)
		end
	end
	part(counts.Error, "error")
	part(counts.Warning, "warning")
	part(counts.Note, "note")
	return table.concat(parts, "  ·  ")
end

-- List entries ----------------------------------------------------------------------------------------------

-- Swaps entry `index` with its neighbour `delta` (+-1) away. False (and nothing changed) at either end.
function DomainInsight.Shift(list: { any }, index: number, delta: number): boolean
	local other = index + delta
	if list[index] == nil or other < 1 or other > #list then
		return false
	end
	list[index], list[other] = list[other], list[index]
	return true
end

-- Inserts a copy of entry `index` right after it, through `fields` (the entry's DomainTypes field list, so
-- the copy is exactly the schema's fields). False when the list is already `max` long.
function DomainInsight.DuplicateAt(list: { any }, index: number, max: number, fields: { { Name: string } }): boolean
	local source = list[index]
	if source == nil or #list >= max then
		return false
	end
	local copy = {}
	for _, field in fields do
		copy[field.Name] = source[field.Name]
	end
	table.insert(list, index + 1, copy)
	return true
end

-- A new effect of `kind`, with a magnitude that means something for that kind (the shared default is 10,
-- which is a 1.5s-capped stun or a crawl of a pull).
local KIND_MAGNITUDE: { [string]: number } = {
	Hitstun = 0.35,
	GuardDrain = 12,
	Pull = 30,
	Push = 45,
}
function DomainInsight.NewEffect(kind: string): DomainTypes.Effect
	local effect = DomainTypes.DefaultEffect()
	effect.Kind = kind :: any
	effect.Magnitude = KIND_MAGNITUDE[kind] or effect.Magnitude
	if kind == "OwnerCast" then
		effect.IntervalSeconds = 4
		effect.FirstDelaySeconds = 1
	end
	return effect
end

function DomainInsight.NewRule(kind: string): DomainTypes.Rule
	local rule = DomainTypes.DefaultRule()
	rule.Kind = kind :: any
	if DomainTypes.ScaleRules[kind] then
		-- A starting multiplier that does something, in the direction the rule's name reads.
		rule.Value = if kind == "MoveSpeed" then 0.7 elseif kind == "DamageDealt" then 0.8 else 1.25
	end
	return rule
end

-- Archetypes ------------------------------------------------------------------------------------------------

export type Archetype = {
	Id: string,
	Text: string,
	Describe: string,
	-- Rewrites the realm block in place. Its clash overrides (answers to particular realms, an identity the
	-- archetype knows nothing about) are kept; every other field is the archetype's.
	Apply: (domain: DomainSpec) -> (),
}

local function reset(domain: DomainSpec): ()
	local fresh = DomainTypes.Defaults() :: any
	for _, field in DomainTypes.Fields do
		(domain :: any)[field.Name] = fresh[field.Name]
	end
	domain.Effects = {}
	domain.Rules = {}
end

local function effect(kind: string, fields: { [string]: any }): DomainTypes.Effect
	local entry = DomainInsight.NewEffect(kind) :: any
	for key, value in fields do
		entry[key] = value
	end
	return entry
end

local function rule(kind: string, value: number, affects: string?): DomainTypes.Rule
	local entry = DomainInsight.NewRule(kind)
	entry.Value = value
	entry.Affects = (affects or "Enemies") :: any
	return entry
end

DomainInsight.Archetypes = {
	{
		Id = "Arena",
		Text = "Sealed arena",
		Describe = "A fixed, walled cylinder nobody enters or leaves and no shot crosses. Its own strike falls every 3s; the trapped lose their escape mobility.",
		Apply = function(domain: DomainSpec)
			reset(domain)
			domain.Shape = "Cylinder"
			domain.Radius = 40
			domain.Height = 40
			domain.EntryRule = "Barred"
			domain.ExitRule = "Barred"
			domain.BoundaryCollision = true
			domain.ProjectilesEnter = false
			domain.ProjectilesLeave = false
			domain.CancelOnOwnerExit = true
			table.insert(domain.Effects, effect("Strike", { IntervalSeconds = 3, FirstDelaySeconds = 1 }))
			table.insert(domain.Rules, rule("NoParkour", 1))
		end,
	},
	{
		Id = "Aura",
		Text = "Mobile aura",
		Describe = "A small realm that follows its owner and costs Qi to hold: it drains nearby guards every second, slows enemies and quickens the owner.",
		Apply = function(domain: DomainSpec)
			reset(domain)
			domain.Anchor = "FollowOwner"
			domain.Radius = 18
			domain.Height = 18
			domain.ActiveSeconds = 10
			domain.UpkeepQiPerSecond = 4
			domain.CancelOnOwnerHit = false
			table.insert(domain.Effects, effect("GuardDrain", { IntervalSeconds = 1, Magnitude = 8 }))
			table.insert(domain.Rules, rule("MoveSpeed", 0.8))
			table.insert(domain.Rules, rule("MoveSpeed", 1.15, "Owner"))
		end,
	},
	{
		Id = "Pressure",
		Text = "Pressure field",
		Describe = "Relentless offence: three own strikes every 1.5s at the nearest, a short stun every 4s, and enemies take more damage to body and guard.",
		Apply = function(domain: DomainSpec)
			reset(domain)
			table.insert(domain.Effects, effect("Strike", { IntervalSeconds = 1.5, MaxPerPulse = 3 }))
			table.insert(
				domain.Effects,
				effect("Hitstun", { IntervalSeconds = 4, FirstDelaySeconds = 2, Magnitude = 0.3 })
			)
			table.insert(domain.Rules, rule("DamageTaken", 1.2))
			table.insert(domain.Rules, rule("GuardDamageTaken", 1.3))
		end,
	},
	{
		Id = "Sanctuary",
		Text = "Sanctuary",
		Describe = "A defensive ward: enemies are barred from entering and pushed out, outside shots stop at the edge, and the owner and allies take less.",
		Apply = function(domain: DomainSpec)
			reset(domain)
			domain.Shape = "Cylinder"
			domain.Radius = 28
			domain.Height = 30
			domain.EntryRule = "Barred"
			domain.ProjectilesEnter = false
			table.insert(domain.Effects, effect("Push", { IntervalSeconds = 2, Magnitude = 45 }))
			table.insert(domain.Rules, rule("DamageTaken", 0.6, "OwnerAndAllies"))
			table.insert(domain.Rules, rule("HitstunTaken", 0.7, "OwnerAndAllies"))
		end,
	},
	{
		Id = "Suppression",
		Text = "Suppression",
		Describe = "Takes the tools away: enemies inside cannot cast arts, throw projectiles or open realms, and their cooldowns run long. Wins most clashes.",
		Apply = function(domain: DomainSpec)
			reset(domain)
			domain.Radius = 40
			domain.Priority = 30
			table.insert(domain.Rules, rule("SealArts", 1))
			table.insert(domain.Rules, rule("SealProjectiles", 1))
			table.insert(domain.Rules, rule("SealDomains", 1))
			table.insert(domain.Rules, rule("Cooldown", 1.5))
		end,
	},
	{
		Id = "Breaker",
		Text = "Realm breaker",
		Describe = "Built to win clashes: high priority, claims ties, and collapses any weaker realm it meets. Short, with its own strike every 2s.",
		Apply = function(domain: DomainSpec)
			reset(domain)
			domain.ActiveSeconds = 8
			domain.Priority = 60
			domain.ClashBehavior = "Dominate"
			domain.TieBreak = "Newer"
			table.insert(domain.Effects, effect("Strike", { IntervalSeconds = 2 }))
			table.insert(domain.Rules, rule("SealDomains", 1))
		end,
	},
} :: { Archetype }

function DomainInsight.ArchetypeById(id: string): Archetype?
	for _, archetype in DomainInsight.Archetypes do
		if archetype.Id == id then
			return archetype
		end
	end
	return nil
end

return DomainInsight
