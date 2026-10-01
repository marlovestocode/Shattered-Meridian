--!strict
--[[
	MoveEditor/PresentationTab.lua

	Owns: the Presentation tab -- what the open move sounds and looks like at each of its moments
	(MoveDefinition.Presentation, Shared/Combat/MovePresentationTypes.lua). One folding group per moment,
	each holding only the fields that moment's runtime reads (MovePresentationTypes.Moments[].Fields --
	the same list Validate keeps), a Preview that plays that moment's cue on this client through the
	runtime's own path, and a Reset that clears the moment back to its defaults.

	BUILT FROM THE SCHEMA. Every group and field comes from MovePresentationTypes' moment and field lists,
	so a moment or field added there appears here with no second list to keep in step; only the labels,
	units and step sizes are this file's (FIELD_UI).

	BLANK IS "INHERIT", EVERYWHERE. The block stores only what the author set: a text field cleared, a
	choice set back to Default, or a number set back to the value shown for "unset" (the scale's identity,
	or the runtime's own default for this moment) removes the field; a moment with nothing left is
	removed; a block with no moments is removed. So an untouched move stays byte-identical to a move from
	before this tab existed -- same Fingerprint, same record.

	Projectile moments are hidden on a melee move (they could never fire) and every other moment is shown
	for both move types -- a projectile move still winds up and still lands hits. Presentation is one of
	the few things a Default (weapon) move may override (DefaultMoveRegistry's header), so nothing here is
	hidden for one.

	Does not own: playing a preview (the driver, Client/DevTools/MoveEditor/PresentationPreview.lua), the
	bounds (MovePresentationTypes.Limits) or the schema.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Move = MoveTypes.MoveDefinition

export type PresentationTabProps = {
	-- (moment) -- play that moment's cue from the draft, locally.
	OnPreview: (moment: string) -> (),
}

type FieldUI = {
	Label: string,
	Unit: string?,
	Steps: { number }?,
	Decimals: number?,
	Placeholder: string?,
}

local FIELD_UI: { [string]: FieldUI } = {
	SoundId = { Label = "Sound id", Placeholder = "blank = default  ·  None  ·  rbxassetid://..." },
	Volume = { Label = "Volume", Unit = "x", Steps = { 0.05, 0.25 }, Decimals = 2 },
	Pitch = { Label = "Pitch", Unit = "x", Steps = { 0.01, 0.1 }, Decimals = 2 },
	PitchVariance = { Label = "Pitch variance", Unit = "+/-", Steps = { 0.01, 0.05 }, Decimals = 2 },
	RolloffDistance = { Label = "Heard up to", Unit = "studs, 0 = everywhere", Steps = { 5, 50 }, Decimals = 0 },
	Loop = { Label = "Loop" },
	FadeIn = { Label = "Fade in", Unit = "seconds", Steps = { 0.05, 0.25 }, Decimals = 2 },
	FadeOut = { Label = "Fade out", Unit = "seconds", Steps = { 0.05, 0.25 }, Decimals = 2 },
	SoundDelay = { Label = "Sound timing", Unit = "seconds, - earlier / + later", Steps = { 0.05, 0.25 }, Decimals = 2 },
	Audience = { Label = "Played for" },
	Sparks = { Label = "Sparks" },
	SparkColor = { Label = "Spark colour", Placeholder = "blank = preset  ·  #RRGGBB" },
	SparkCount = { Label = "Spark count", Unit = "x", Steps = { 0.1, 0.5 }, Decimals = 2 },
	SparkSize = { Label = "Spark size", Unit = "x", Steps = { 0.1, 0.5 }, Decimals = 2 },
	SparkTexture = { Label = "Spark texture id", Placeholder = "blank = default sparkle  ·  rbxassetid://..." },
	Shake = { Label = "Camera shake" },
	ShakeScale = { Label = "Shake strength", Unit = "x", Steps = { 0.1, 0.5 }, Decimals = 2 },
	FovPunch = { Label = "FOV punch" },
	FlashColor = { Label = "Hit flash colour", Placeholder = "blank = default  ·  None  ·  #RRGGBB" },
	HitStopSeconds = { Label = "Freeze", Unit = "seconds", Steps = { 0.01, 0.05 }, Decimals = 2 },
	TrailColor = { Label = "Trail colour", Placeholder = "blank = default  ·  None  ·  #RRGGBB" },
	CoreColor = { Label = "Core colour", Placeholder = "blank = default  ·  #RRGGBB" },
	GlowColor = { Label = "Glow colour", Placeholder = "blank = core colour  ·  #RRGGBB" },
	TrailLifetime = { Label = "Trail length", Unit = "seconds", Steps = { 0.02, 0.1 }, Decimals = 2 },
	SizeScale = { Label = "Glow size", Unit = "x", Steps = { 0.1, 0.5 }, Decimals = 2 },
	Template = { Label = "Template", Placeholder = "a child of ReplicatedStorage.MoveFX" },
}

-- The number an ABSOLUTE field shows while unset: what the runtime plays for this moment with no cue.
-- (A scale shows its Identity.) Setting a field back to this value unsets it.
local HIT_STOP = FXConstants.HitStop
local HIT_STOP_DEFAULTS: { [string]: number } = {
	HitClean = HIT_STOP.VictimSeconds,
	HitBackstab = HIT_STOP.PostureBreakSeconds,
	HitGuardBroken = HIT_STOP.PostureBreakSeconds,
	HitParried = HIT_STOP.ParrySeconds,
	HitPerfectParry = HIT_STOP.PerfectParrySeconds,
}

local function unsetNumber(moment: string, field: MovePresentationTypes.Field): number
	if field.Identity then
		return field.Identity
	end
	if field.Name == "HitStopSeconds" then
		return HIT_STOP_DEFAULTS[moment] or 0
	elseif field.Name == "PitchVariance" then
		return CombatConstants.Sound.PitchJitter
	elseif field.Name == "TrailLifetime" then
		return FXConstants.Projectile.TrailLifetimeSeconds
	end
	return MovePresentationTypes.Limits[field.Name].Min
end

local function cueOf(move: Move, moment: string): { [string]: any }?
	local presentation = move.Presentation
	return if presentation then presentation[moment] :: any else nil
end

-- The one write: sets (or, with nil, unsets) one field, pruning an emptied cue and an emptied block --
-- see this file's header. `move` is always Edit's clone, so mutating it is safe.
local function setField(move: Move, moment: string, fieldName: string, value: any): ()
	local presentation = (move.Presentation or {}) :: { [string]: any }
	local cue = presentation[moment] or {}
	cue[fieldName] = value
	presentation[moment] = if next(cue) ~= nil then cue else nil
	move.Presentation = if next(presentation) ~= nil then presentation :: any else nil
end

local function clearMoment(move: Move, moment: string): ()
	local presentation = move.Presentation
	if presentation == nil then
		return
	end
	presentation[moment] = nil
	if next(presentation) == nil then
		move.Presentation = nil
	end
end

local function choiceOptions(field: MovePresentationTypes.Field): { { Value: string, Text: string } }
	local options = { { Value = "", Text = field.DefaultText or "Default" } }
	for _, option in field.Options :: { string } do
		table.insert(
			options,
			{ Value = option, Text = if field.OptionText then field.OptionText[option] or option else option }
		)
	end
	return options
end

local function PresentationTab(
	scope: Scope,
	context: Fields.FormContext,
	props: PresentationTabProps,
	visible: UsedAs<boolean>
): ScrollingFrame
	local isProjectile = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and MoveTypes.IsProjectile(move)
	end)
	local isMelee = scope:Computed(function(use)
		return not use(isProjectile)
	end)
	local isDomain = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and MoveTypes.IsDomain(move)
	end)
	local isNotDomain = scope:Computed(function(use)
		return not use(isDomain)
	end)

	local children: { Instance } = {
		Fields.Prose(scope, Copy.Presentation.Precedence, 1),
		Fields.Prose(scope, Copy.Presentation.Melee, 2, isMelee),
		Fields.Prose(scope, Copy.Presentation.NoRealm, 3, isNotDomain),
	}

	local order = 10
	local function nextOrder(): number
		order += 1
		return order
	end

	for _, moment in MovePresentationTypes.Moments do
		local momentName = moment.Name
		local momentVisible: UsedAs<boolean> = if moment.Group == "Projectile"
			then isProjectile
			elseif moment.Group == "Domain" then isDomain
			else true

		local heading, shown = Fields.Fold(scope, string.upper(moment.Label), nextOrder(), momentVisible, true)
		table.insert(children, heading)
		table.insert(children, Fields.Prose(scope, Copy.Presentation.Moments[momentName] or "", nextOrder(), shown))

		for _, fieldName in moment.Fields do
			local field = MovePresentationTypes.Field(fieldName) :: MovePresentationTypes.Field
			local ui = FIELD_UI[fieldName]
			local label = if momentName == "InFlight" and fieldName == "SoundId" then "Loop sound id" else ui.Label
			local hint = (Copy.Hints :: any)[`Presentation{fieldName}`]

			if field.Kind == "Number" then
				local unset = unsetNumber(momentName, field)
				table.insert(
					children,
					Fields.Number(scope, context, {
						Label = label,
						Unit = ui.Unit,
						Range = MovePresentationTypes.Limits[fieldName],
						Steps = ui.Steps or { 0.1, 1 },
						Decimals = ui.Decimals,
						Hint = hint,
						Visible = shown,
						LayoutOrder = nextOrder(),
						Get = function(move)
							local cue = cueOf(move, momentName)
							local value = if cue then cue[fieldName] else nil
							return if typeof(value) == "number" then value else unset
						end,
						Set = function(move, value)
							setField(move, momentName, fieldName, if math.abs(value - unset) < 1e-6 then nil else value)
						end,
					})
				)
			elseif field.Kind == "Choice" then
				table.insert(
					children,
					Fields.Choice(scope, context, {
						Label = label,
						Options = choiceOptions(field),
						Visible = shown,
						LayoutOrder = nextOrder(),
						Get = function(move)
							local cue = cueOf(move, momentName)
							local value = if cue then cue[fieldName] else nil
							return if typeof(value) == "string" then value else ""
						end,
						Set = function(move, value)
							setField(move, momentName, fieldName, if value == "" then nil else value)
						end,
					})
				)
				if hint then
					table.insert(children, Fields.Prose(scope, hint, nextOrder(), shown))
				end
			else
				-- Asset, Color and Name are all text the server normalises (and refuses, with a reason the
				-- footer shows, when it cannot).
				table.insert(
					children,
					Fields.Text(scope, context, {
						Label = label,
						Placeholder = ui.Placeholder,
						MaxLength = if field.Kind == "Name"
							then MovePresentationTypes.TemplateNameLength
							else MovePresentationTypes.AssetIdLength,
						Hint = hint,
						Visible = shown,
						LayoutOrder = nextOrder(),
						Get = function(move)
							local cue = cueOf(move, momentName)
							local value = if cue then cue[fieldName] else nil
							return if typeof(value) == "string" then value else ""
						end,
						Set = function(move, value)
							local trimmed = string.match(value, "^%s*(.-)%s*$") or ""
							setField(move, momentName, fieldName, if trimmed == "" then nil else trimmed)
						end,
					})
				)
			end
		end

		table.insert(
			children,
			Fields.Pair(
				scope,
				nextOrder(),
				Button(scope, {
					Text = "Preview",
					Variant = "Secondary",
					Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
					OnActivated = function()
						props.OnPreview(momentName)
					end,
				}),
				Button(scope, {
					Text = "Reset to defaults",
					Variant = "Secondary",
					Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
					OnActivated = function()
						context.Edit(function(move)
							clearMoment(move, momentName)
						end)
					end,
				}),
				shown
			)
		)
	end

	return Fields.Page(scope, "PresentationTab", visible, children)
end

return PresentationTab
