--!strict
--[[
	MovePresentationTypes.lua

	Owns: the per-move PRESENTATION schema -- the optional MoveDefinition.Presentation block that lets a
	move author what it sounds and looks like at a small fixed set of moments -- plus the ONE field list
	every copy, encoding and validation of it walks (ProjectileTypes' arrangement), the authorable bounds
	the editor renders from, and the catalogue wire contract that gets it to clients.

	PRESENTATION ONLY. Nothing in this block reaches a hit, a timing or anything the server decides: no
	combat layer reads it, MoveTypes.ToEngineAttackDefinition does not project it, and every consumer is a
	client FX module. A crafted value can make a move look wrong, never play wrong.

	PRECEDENCE, and every consumer follows it field by field:

	    move config  >  the weapon's authored SFX folder  >  FXConstants / CombatConstants defaults

	An UNSET field falls through to the next layer. Unset never means silent or invisible; only the
	explicit None does ("None" in a SoundId, a Color or a Choice). A move that sets only Pitch on its Hit
	(Blocked) cue still clangs with its defender's own SFX/Block, just lower. The weapon layer exists only
	where a weapon authors that moment today -- the swing whoosh (SFX/Swing, the Active moment) and the
	block/parry clang (SFX/Block, SFX/Parry) -- everywhere else the move falls straight to the defaults.
	One sibling fallback sits INSIDE the move layer: a Perfect parry cue's unset fields read the move's
	Parried cue before leaving the move (FallbackMoment), because a perfect parry is a parry.

	THE MOMENTS, and the event each one hangs off. Every one is an event a client ALREADY receives:

	  Swing (the attacker's client only -- Attack_Started is a FireClient; no client learns another's
	  swing started, so these cues are the thrower's alone, exactly like today's whoosh and trail):
	    Windup     Attack_Started arriving
	    Active     WindupSeconds after it (the payload's own scheduled windup)
	    Recovery   WindupSeconds + ActiveSeconds after it
	    A cancelled swing (Attack_Cancelled / a local hitstun cut) drops its pending cues.
	  Hit (Combat_Feedback, both participants -- keyed by DefenseTypes.OutcomeKind, plus the Perfect
	  variant the payload flags): HitClean, HitBlocked, HitParried, HitPerfectParry, HitGuardBroken,
	  HitBackstab, HitTrade, HitEvaded.
	  Projectile (Attack_Projectile, every client):
	    Launch       a shot's first Launch event (once per volley, not per shot)
	    InFlight     the shot's own look for its whole flight, and a looping sound
	    Bounce       an Update event tagged Reason = "Bounce" (ProjectileSimulator)
	    WorldImpact  an End event with Reason "World"
	    End          an End event with Reason "Range" or "Expired" -- a shot that fizzles. A shot that
	                 ends on a BODY is a Hit, and plays the Hit cue off Combat_Feedback like any contact.

	  Domain (Domain_State, every client -- only on a move carrying a Domain block, DomainTypes):
	    DomainOpen    the realm begins to unfurl (Activating), at its centre
	    DomainActive  the realm is established (Active) -- its CoreColor tints the realm and its
	                  GlowColor draws the edge; both fall back to FXConstants.Domain
	    DomainPulse   one of the realm's effects fires, at each body it touched
	    DomainClose   the realm starts to fold away (Ending), at its centre
	    Audience "Participants" plays a domain cue only for the owner and the bodies the realm governs.

	NOT HERE, and why: a grab's Hold and Throw. Grab_HoldChanged carries no MoveId, so a client cannot
	tell whose grab it is; the hold begins on the move's own Clean contact, which HitClean already covers.
	A Throw cue would need a MoveId added to that payload -- a new signal, deliberately not invented here.

	SOUND TIMING (SoundDelay). A moment's sound plays when the moment does -- and a moment's look and its sound
	are authored on two different clocks, so they drift: a realm's "established" cue fires on the phase
	message, after the unfurl has already looked finished (an eased growth reads as formed well before its
	last frame), and a network hop later than the clock said. SoundDelay is the author's control over that:
	signed seconds from the moment, positive LATER, negative EARLIER. A positive value is honoured on every
	moment. A negative one (a lead) needs the moment to be known AHEAD, so it is honoured only where the
	client already knows the schedule -- a swing's Active (whoosh) and Recovery, and a realm's Established
	and Fold -- and clamps to "now" everywhere else (a hit, a launch, a realm's unfurl are not foreseeable).
	Only the sound moves; the moment's sparks, camera and template stay on it. Sounds are therefore placed
	against each other by their moments' offsets: two cues' sounds land SoundDelay apart plus whatever
	separates their moments.

	SOUND FADES (FadeIn, FadeOut). A cue's sound can rise from silence over FadeIn seconds and sink back to
	silence over its last FadeOut seconds -- either, or both for a fade in AND out. They are independent
	numbers rather than a mode: 0 / unset is no fade on that edge. The fade-out is timed from the sound's own
	remaining playtime (so it lands on the sound's real end, at its real pitch), and when the sound is
	shorter than the two fades together the fade-out takes over from wherever the fade-in had got to. One-shot moments only: a shot's looping
	InFlight sound is stopped by its carrier being released, not by running out, so it has no end to fade
	toward and does not offer them.

	SOUND LOOPS (Loop = "RestOfMove"). The cue's OWN sound (a SoundId it names -- there is nothing to loop
	otherwise) repeats from its moment until the move ends, then stops, sinking over FadeOut so the fade lands on
	the move's last instant. "The move ends" is the swing's own end (windup + active + recovery) for a swing
	moment, and the realm's last instant (the end of its fold) for a realm moment; a swing that is cancelled or
	replaced stops its loops, and a realm that collapses early stops them as it folds. Offered on the swing
	moments and the realm's Unfurl, Established and Fold; not on a hit, a shot's moments (its flight has its own
	loop) or a realm's pulse, which are instants. A cap on concurrent loops (FXConstants.MovePresentation
	.MaxLoopingCues) means a crowd cannot pile them up: a loop past it simply does not start.

	THE FIELDS a moment offers are the ones its runtime reads (Moments[].Fields); Validate drops anything
	else, so a field on a moment that cannot use it is never stored. Numbers are CLAMPED (lenient), names
	and ids are REJECTED (strict) -- the split every block in MoveRegistryManager.Validate keeps. Every
	asset id is normalised with WeaponAssets.NormalizeAssetId here, once, so no reader re-normalises.

	THE CATALOGUE (Network below). The move registry is server-side and a client handed only a MoveId
	cannot look a move up, so Server/Combat/MovePresentationSystem.lua replicates MoveId -> Presentation:
	a Snapshot on request (a client's first ask, at start), then a Delta whenever a Preview/Save/Delete/
	Reset actually changes one. Versioned: a Delta names the version it applies on top of, and a client
	whose version differs knows it is stale and asks again. Chosen over shipping the fields on every
	Attack_Started/Combat_Feedback/Launch because a client must know an asset id BEFORE the moment that
	plays it to have preloaded it -- a payload-borne id is always a cold first play -- and because the
	catalogue costs one small message per edit rather than the same bytes on every hit of every fight.

	Does not own: playing anything (Client/FX/MovePresentation.lua and the FX modules it feeds), the move
	schema around the block (MoveTypes), where the catalogue is built (MovePresentationSystem), or the
	preload pass (Client/Loading/AssetPreloader.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Sanitize = require(ReplicatedStorage.Shared.Sanitize)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)

local MovePresentationTypes = {}

-- The explicit "nothing at all" -- the one value that silences a sound or hides an effect.
MovePresentationTypes.None = "None"
local NONE = MovePresentationTypes.None

export type MomentGroup = "Swing" | "Hit" | "Projectile" | "Domain"

-- One moment's authored overrides. Every field optional; see the header for what unset means.
export type Cue = {
	-- Sound
	SoundId: string?,
	Volume: number?,
	Pitch: number?,
	PitchVariance: number?,
	RolloffDistance: number?,
	-- Seconds the sound is shifted from its moment: positive plays it later, negative EARLIER (a lead) --
	-- see the header's SOUND TIMING.
	SoundDelay: number?,
	-- Seconds the sound takes to rise from silence / to sink back to it before it ends -- see the header's
	-- SOUND FADES. Either, or both for a fade in AND out; unset is no fade.
	FadeIn: number?,
	FadeOut: number?,
	-- "RestOfMove": the cue's own sound loops from its moment until the move ends -- see the header's SOUND
	-- LOOPS. Unset plays once.
	Loop: string?,
	Audience: string?,
	-- Sparks (Client/FX/ImpactSparks.lua)
	Sparks: string?,
	SparkColor: string?,
	SparkCount: number?,
	SparkSize: number?,
	SparkTexture: string?,
	-- Camera (CameraShake / FOVOffset -- both gated by settings.Comfort)
	Shake: string?,
	ShakeScale: number?,
	FovPunch: string?,
	-- Impact (HitFlash / HitStop.FreezeExchange)
	FlashColor: string?,
	HitStopSeconds: number?,
	-- Look (the swing trail, and a shot in flight)
	TrailColor: string?,
	CoreColor: string?,
	GlowColor: string?,
	TrailLifetime: number?,
	SizeScale: number?,
	-- An authored effect from ReplicatedStorage[FXConstants.MovePresentation.TemplateFolder], by Name.
	Template: string?,
}

-- Moment name -> cue. Absent moments are not authored.
export type Presentation = { [string]: Cue }

type Range = { Min: number, Max: number }

-- Option lists ----------------------------------------------------------------------------------------

local function sortedKeys(source: { [string]: any }, accept: ((any) -> boolean)?): { string }
	local keys: { string } = {}
	for key, value in source do
		if accept == nil or accept(value) then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys
end

local function withNone(options: { string }): { string }
	local result = { NONE }
	for _, option in options do
		table.insert(result, option)
	end
	return result
end

-- Read from the tables the effects themselves read, so a preset added there is offered here, and one
-- removed there is refused here rather than silently doing nothing.
MovePresentationTypes.SparkPresets = sortedKeys(FXConstants.ImpactSparks.Presets :: any)
MovePresentationTypes.ShakePresets = sortedKeys(FXConstants.CameraShake :: any, function(value: any): boolean
	return typeof(value) == "table" and typeof(value.Amplitude) == "number"
end)
MovePresentationTypes.FovPunches = sortedKeys(FXConstants.ImpactSparks.Punches :: any)
-- Everyone: every client the moment's event reaches. Participants: only the thrower and the shot's
-- homing target (a domain moment: the realm's owner and the bodies it governs). Offered only on projectile
-- and domain moments -- a swing cue already reaches only its thrower and a hit cue only its two
-- participants, so the choice would change nothing there.
MovePresentationTypes.Audiences = { "Everyone", "Participants" }
-- The one looping choice: from the cue's moment to the end of the move. Unset (the editor's "Play once") is the
-- default, so it is not an option of its own.
MovePresentationTypes.Loops = { "RestOfMove" }

-- Bounds ------------------------------------------------------------------------------------------------

-- Validate clamps against these and the editor renders its fields from them. Scales are multipliers of
-- whatever the answering layer would have played (1 = unchanged); the rest are absolute.
MovePresentationTypes.Limits = {
	Volume = { Min = 0, Max = 4 },
	Pitch = { Min = 0.25, Max = 4 },
	PitchVariance = { Min = 0, Max = 0.5 },
	RolloffDistance = { Min = 0, Max = 1000 },
	SoundDelay = { Min = -2, Max = 2 },
	FadeIn = { Min = 0, Max = 5 },
	FadeOut = { Min = 0, Max = 5 },
	SparkCount = { Min = 0, Max = 5 },
	SparkSize = { Min = 0.1, Max = 5 },
	ShakeScale = { Min = 0, Max = 3 },
	HitStopSeconds = { Min = 0, Max = 0.3 },
	TrailLifetime = { Min = 0.02, Max = 2 },
	SizeScale = { Min = 0.25, Max = 4 },
} :: { [string]: Range }

MovePresentationTypes.AssetIdLength = 120
MovePresentationTypes.TemplateNameLength = 64

-- The field list -------------------------------------------------------------------------------------

export type FieldKind = "Asset" | "Color" | "Choice" | "Number" | "Name"
export type AssetKind = "Sound" | "Image"

export type Field = {
	Name: string,
	Kind: FieldKind,
	-- The editor's grouping inside a moment.
	Section: "Sound" | "Sparks" | "Camera" | "Impact" | "Look" | "Template",
	-- Asset: what the id must be.
	AssetKind: AssetKind?,
	-- Asset / Color: whether None is a legal value.
	AllowNone: boolean?,
	-- Choice: the legal values (None among them where it means something).
	Options: { string }?,
	-- Choice: what the editor calls "unset" (default: "Default"), and a readable label for an option whose
	-- stored value is not one.
	DefaultText: string?,
	OptionText: { [string]: string }?,
	-- Number: the value that means "unchanged" for a scale, which the editor shows when unset.
	Identity: number?,
}

-- THE schema. Order is the order the editor lays a moment's fields out in.
MovePresentationTypes.Fields = {
	{ Name = "SoundId", Kind = "Asset", Section = "Sound", AssetKind = "Sound", AllowNone = true },
	{ Name = "Volume", Kind = "Number", Section = "Sound", Identity = 1 },
	{ Name = "Pitch", Kind = "Number", Section = "Sound", Identity = 1 },
	{ Name = "PitchVariance", Kind = "Number", Section = "Sound" },
	{ Name = "RolloffDistance", Kind = "Number", Section = "Sound", Identity = 0 },
	{ Name = "SoundDelay", Kind = "Number", Section = "Sound", Identity = 0 },
	{ Name = "FadeIn", Kind = "Number", Section = "Sound", Identity = 0 },
	{ Name = "FadeOut", Kind = "Number", Section = "Sound", Identity = 0 },
	{
		Name = "Loop",
		Kind = "Choice",
		Section = "Sound",
		Options = MovePresentationTypes.Loops,
		DefaultText = "Play once",
		OptionText = { RestOfMove = "Loop for the rest of the move" },
	},
	{ Name = "Audience", Kind = "Choice", Section = "Sound", Options = MovePresentationTypes.Audiences },
	{ Name = "Sparks", Kind = "Choice", Section = "Sparks", Options = withNone(MovePresentationTypes.SparkPresets) },
	{ Name = "SparkColor", Kind = "Color", Section = "Sparks" },
	{ Name = "SparkCount", Kind = "Number", Section = "Sparks", Identity = 1 },
	{ Name = "SparkSize", Kind = "Number", Section = "Sparks", Identity = 1 },
	{ Name = "SparkTexture", Kind = "Asset", Section = "Sparks", AssetKind = "Image" },
	{ Name = "Shake", Kind = "Choice", Section = "Camera", Options = withNone(MovePresentationTypes.ShakePresets) },
	{ Name = "ShakeScale", Kind = "Number", Section = "Camera", Identity = 1 },
	{ Name = "FovPunch", Kind = "Choice", Section = "Camera", Options = withNone(MovePresentationTypes.FovPunches) },
	{ Name = "FlashColor", Kind = "Color", Section = "Impact", AllowNone = true },
	{ Name = "HitStopSeconds", Kind = "Number", Section = "Impact" },
	{ Name = "TrailColor", Kind = "Color", Section = "Look", AllowNone = true },
	{ Name = "CoreColor", Kind = "Color", Section = "Look" },
	{ Name = "GlowColor", Kind = "Color", Section = "Look" },
	{ Name = "TrailLifetime", Kind = "Number", Section = "Look" },
	{ Name = "SizeScale", Kind = "Number", Section = "Look", Identity = 1 },
	{ Name = "Template", Kind = "Name", Section = "Template" },
} :: { Field }

local FIELD_BY_NAME: { [string]: Field } = {}
for _, field in MovePresentationTypes.Fields do
	FIELD_BY_NAME[field.Name] = field
end

function MovePresentationTypes.Field(name: string): Field?
	return FIELD_BY_NAME[name]
end

-- The moments --------------------------------------------------------------------------------------------

local SOUND = { "SoundId", "Volume", "Pitch", "PitchVariance", "RolloffDistance", "SoundDelay", "FadeIn", "FadeOut" }
-- A swing cue is heard by its thrower alone, standing at its source: a rolloff would change nothing.
local SWING_SOUND = { "SoundId", "Volume", "Pitch", "PitchVariance", "SoundDelay", "FadeIn", "FadeOut", "Loop" }
local CAMERA = { "Shake", "ShakeScale", "FovPunch" }
local SPARKS = { "Sparks", "SparkColor", "SparkCount", "SparkSize", "SparkTexture" }
local IMPACT = { "FlashColor", "HitStopSeconds" }

local function fields(...: { string } | string): { string }
	local result: { string } = {}
	for _, part in { ... } do
		if typeof(part) == "string" then
			table.insert(result, part)
		else
			for _, name in part :: { string } do
				table.insert(result, name)
			end
		end
	end
	return result
end

export type Moment = {
	Name: string,
	Group: MomentGroup,
	Label: string,
	-- Which of Fields this moment's runtime reads.
	Fields: { string },
	-- Hit moments: the OutcomeKind it answers, and whether only the Perfect variant.
	Outcome: string?,
	Perfect: boolean?,
}

MovePresentationTypes.Moments = {
	{ Name = "Windup", Group = "Swing", Label = "Windup starts", Fields = fields(SWING_SOUND, CAMERA, "Template") },
	{
		Name = "Active",
		Group = "Swing",
		Label = "Hit window opens",
		Fields = fields(SWING_SOUND, CAMERA, "TrailColor", "Template"),
	},
	{ Name = "Recovery", Group = "Swing", Label = "Recovery", Fields = fields(SWING_SOUND, CAMERA, "Template") },

	{
		Name = "HitClean",
		Group = "Hit",
		Label = "Hit: clean",
		Outcome = "Clean",
		Fields = fields(SOUND, SPARKS, CAMERA, IMPACT, "Template"),
	},
	{
		Name = "HitBlocked",
		Group = "Hit",
		Label = "Hit: blocked",
		Outcome = "Blocked",
		Fields = fields(SOUND, SPARKS, CAMERA, IMPACT, "Template"),
	},
	{
		Name = "HitParried",
		Group = "Hit",
		Label = "Hit: parried",
		Outcome = "Parried",
		Fields = fields(SOUND, SPARKS, CAMERA, IMPACT, "Template"),
	},
	{
		Name = "HitPerfectParry",
		Group = "Hit",
		Label = "Hit: perfect parry",
		Outcome = "Parried",
		Perfect = true,
		Fields = fields(SOUND, SPARKS, CAMERA, IMPACT, "Template"),
	},
	{
		Name = "HitGuardBroken",
		Group = "Hit",
		Label = "Hit: guard broken",
		Outcome = "GuardBroken",
		Fields = fields(SOUND, SPARKS, CAMERA, IMPACT, "Template"),
	},
	{
		Name = "HitBackstab",
		Group = "Hit",
		Label = "Hit: backstab",
		Outcome = "Backstab",
		Fields = fields(SOUND, SPARKS, CAMERA, IMPACT, "Template"),
	},
	{
		Name = "HitTrade",
		Group = "Hit",
		Label = "Hit: trade",
		Outcome = "Trade",
		Fields = fields(SOUND, SPARKS, CAMERA, IMPACT, "Template"),
	},
	-- No flash and no freeze: nothing touched the dodger, and a flash on a body the swing went through
	-- would say it had (CombatFeedbackClient's own rule for Evaded).
	{
		Name = "HitEvaded",
		Group = "Hit",
		Label = "Hit: evaded",
		Outcome = "Evaded",
		Fields = fields(SOUND, SPARKS, CAMERA, "Template"),
	},

	{
		Name = "Launch",
		Group = "Projectile",
		Label = "Launch",
		Fields = fields(SOUND, "Audience", CAMERA, "Template"),
	},
	{
		Name = "InFlight",
		Group = "Projectile",
		Label = "In flight",
		Fields = fields(
			"SoundId",
			"Volume",
			"Pitch",
			"RolloffDistance",
			"Audience",
			"CoreColor",
			"GlowColor",
			"TrailColor",
			"TrailLifetime",
			"SizeScale"
		),
	},
	{
		Name = "Bounce",
		Group = "Projectile",
		Label = "Bounce",
		Fields = fields(SOUND, "Audience", SPARKS, "Template"),
	},
	{
		Name = "WorldImpact",
		Group = "Projectile",
		Label = "Hits the world",
		Fields = fields(SOUND, "Audience", SPARKS, "Template"),
	},
	{
		Name = "End",
		Group = "Projectile",
		Label = "Fizzles out",
		Fields = fields(SOUND, "Audience", SPARKS, "Template"),
	},

	{
		Name = "DomainOpen",
		Group = "Domain",
		Label = "Realm unfurls",
		Fields = fields(SOUND, "Loop", "Audience", CAMERA, "Template"),
	},
	{
		Name = "DomainActive",
		Group = "Domain",
		Label = "Realm established",
		Fields = fields(SOUND, "Loop", "Audience", CAMERA, "CoreColor", "GlowColor", "Template"),
	},
	{
		Name = "DomainPulse",
		Group = "Domain",
		Label = "Realm effect fires",
		Fields = fields(SOUND, "Audience", SPARKS, "Template"),
	},
	{
		Name = "DomainClose",
		Group = "Domain",
		Label = "Realm folds away",
		Fields = fields(SOUND, "Loop", "Audience", CAMERA, "Template"),
	},
} :: { Moment }

local MOMENT_BY_NAME: { [string]: Moment } = {}
local MOMENT_FIELDS: { [string]: { [string]: boolean } } = {}
for _, moment in MovePresentationTypes.Moments do
	MOMENT_BY_NAME[moment.Name] = moment
	local set: { [string]: boolean } = {}
	for _, name in moment.Fields do
		assert(FIELD_BY_NAME[name], `MovePresentationTypes: moment {moment.Name} names unknown field {name}`)
		set[name] = true
	end
	MOMENT_FIELDS[moment.Name] = set
end

-- A Perfect parry cue's unset fields read these moments' cues first, still inside the move layer.
MovePresentationTypes.FallbackMoment = {
	HitPerfectParry = "HitParried",
} :: { [string]: string }

function MovePresentationTypes.Moment(name: string): Moment?
	return MOMENT_BY_NAME[name]
end

-- Whether `moment` offers `fieldName` -- the editor shows a field only where this is true.
function MovePresentationTypes.MomentHasField(moment: string, fieldName: string): boolean
	local set = MOMENT_FIELDS[moment]
	return set ~= nil and set[fieldName] == true
end

-- Whether a moment can ever fire for a move of this type: a projectile moment on a melee move cannot, and
-- a domain moment on a move that opens no realm cannot.
function MovePresentationTypes.IsMomentLive(moment: string, isProjectile: boolean, isDomain: boolean?): boolean
	local definition = MOMENT_BY_NAME[moment]
	if not definition then
		return false
	end
	if definition.Group == "Projectile" then
		return isProjectile
	elseif definition.Group == "Domain" then
		return isDomain == true
	end
	return true
end

-- The Hit moment a Combat_Feedback payload plays, or nil for an outcome with no moment.
function MovePresentationTypes.HitMomentFor(kind: string, perfect: boolean?): string?
	if kind == "Parried" and perfect == true then
		return "HitPerfectParry"
	end
	local name = "Hit" .. kind
	return if MOMENT_BY_NAME[name] then name else nil
end

-- Normalising -----------------------------------------------------------------------------------------

-- "#RRGGBB" (upper case) from "#rrggbb" or "rrggbb", or nil for anything else.
function MovePresentationTypes.NormalizeColor(text: string): string?
	local hex = string.match(text, "^%s*#?(%x%x%x%x%x%x)%s*$")
	if not hex then
		return nil
	end
	return "#" .. string.upper(hex)
end

-- A content id the engine can load: "rbxassetid://<digits>" after normalising, or nil.
function MovePresentationTypes.NormalizeAsset(text: string): string?
	local normalized = WeaponAssets.NormalizeAssetId(text)
	if string.match(normalized, "^rbxassetid://%d+$") then
		return normalized
	end
	return nil
end

local TEMPLATE_NAME_PATTERN = "^[%w_%-%. ]+$"

-- Validation --------------------------------------------------------------------------------------------

-- One field's value, or (nil, reason). An empty string is "unset" for every text kind, so clearing a
-- text box in the editor falls back to the next layer rather than failing.
local function validateField(field: Field, value: unknown): (any, string?)
	local kind = field.Kind
	if kind == "Number" then
		local range = MovePresentationTypes.Limits[field.Name]
		local clamped = Sanitize.ClampNumber(value, range.Min, range.Max)
		if clamped == nil then
			return nil, "InvalidPresentation"
		end
		return clamped, nil
	end

	if kind == "Asset" then
		if typeof(value) ~= "string" then
			return nil, "InvalidPresentationAsset"
		end
		local text = string.match(Sanitize.BoundedString(value, MovePresentationTypes.AssetIdLength), "^%s*(.-)%s*$")
		if text == "" then
			return nil, nil
		end
		if field.AllowNone and string.lower(text :: string) == "none" then
			return NONE, nil
		end
		local asset = MovePresentationTypes.NormalizeAsset(text :: string)
		if not asset then
			return nil, "InvalidPresentationAsset"
		end
		return asset, nil
	end

	if kind == "Color" then
		if typeof(value) ~= "string" then
			return nil, "InvalidPresentationColor"
		end
		local text = value :: string
		if string.match(text, "^%s*$") then
			return nil, nil
		end
		if field.AllowNone and string.lower((string.match(text, "^%s*(.-)%s*$") or "") :: string) == "none" then
			return NONE, nil
		end
		local color = MovePresentationTypes.NormalizeColor(text)
		if not color then
			return nil, "InvalidPresentationColor"
		end
		return color, nil
	end

	if kind == "Choice" then
		if typeof(value) ~= "string" then
			return nil, "UnknownPresentationPreset"
		end
		if value == "" then
			return nil, nil
		end
		if table.find(field.Options :: { string }, value :: string) == nil then
			return nil, "UnknownPresentationPreset"
		end
		return value, nil
	end

	-- Name
	if typeof(value) ~= "string" then
		return nil, "InvalidPresentationTemplate"
	end
	local text = value :: string
	if text == "" then
		return nil, nil
	end
	if #text > MovePresentationTypes.TemplateNameLength or not string.match(text, TEMPLATE_NAME_PATTERN) then
		return nil, "InvalidPresentationTemplate"
	end
	return text, nil
end

-- The gate for an untrusted block -- a client draft, a DataStore record, a source file. Strict on
-- identity: a moment name that does not exist, a preset that does not exist, an id that is not an id, a
-- colour that is not a colour -- each rejects the whole block with a reason code (the editor's
-- Copy.lua has the prose). Lenient on numbers: clamped into Limits. Fields a moment does not offer are
-- dropped, never stored. A cue left with no fields is dropped, and a block with no cues is nil -- so an
-- emptied block digests and persists exactly like one that was never authored.
--
-- nil in, (nil, nil) out: absent is valid and means today's behaviour.
function MovePresentationTypes.Validate(raw: unknown): (Presentation?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidPresentation"
	end
	local result: Presentation = {}
	local any = false
	for momentName, rawCue in raw :: { [any]: unknown } do
		if typeof(momentName) ~= "string" or MOMENT_BY_NAME[momentName] == nil then
			return nil, "UnknownPresentationMoment"
		end
		if typeof(rawCue) ~= "table" then
			return nil, "InvalidPresentation"
		end
		local source = rawCue :: { [string]: unknown }
		local cue = {} :: any
		local hasField = false
		for _, fieldName in MOMENT_BY_NAME[momentName].Fields do
			local value = source[fieldName]
			if value ~= nil then
				local clean, reason = validateField(FIELD_BY_NAME[fieldName], value)
				if reason then
					return nil, reason
				end
				if clean ~= nil then
					cue[fieldName] = clean
					hasField = true
				end
			end
		end
		if hasField then
			result[momentName] = cue :: Cue
			any = true
		end
	end
	return if any then result else nil, nil
end

-- Copying -----------------------------------------------------------------------------------------------

-- A field-by-field copy through each moment's own field list, never a table.clone -- MoveTypes.Clone's
-- reasoning. Every value is a string or a number, so this copy IS the block's flat wire encoding.
function MovePresentationTypes.Copy(presentation: Presentation): Presentation
	local copy: Presentation = {}
	for _, moment in MovePresentationTypes.Moments do
		local cue = presentation[moment.Name]
		if cue then
			local cueCopy = {} :: any
			for _, fieldName in moment.Fields do
				cueCopy[fieldName] = (cue :: any)[fieldName]
			end
			copy[moment.Name] = cueCopy
		end
	end
	return copy
end

-- References ---------------------------------------------------------------------------------------------

export type AssetRef = {
	AssetId: string,
	Kind: AssetKind,
	Moment: string,
	Field: string,
}

-- Every loadable asset a block references, in moment then field order (None is not an asset). What the
-- preload manifest and the editor's notes both walk.
function MovePresentationTypes.AssetRefs(presentation: Presentation?): { AssetRef }
	local refs: { AssetRef } = {}
	if presentation == nil then
		return refs
	end
	for _, moment in MovePresentationTypes.Moments do
		local cue = presentation[moment.Name]
		if cue then
			for _, fieldName in moment.Fields do
				local field = FIELD_BY_NAME[fieldName]
				local value = (cue :: any)[fieldName]
				if field.Kind == "Asset" and typeof(value) == "string" and value ~= NONE then
					table.insert(refs, {
						AssetId = value,
						Kind = field.AssetKind :: AssetKind,
						Moment = moment.Name,
						Field = fieldName,
					})
				end
			end
		end
	end
	return refs
end

-- Every template a block names, as { Name, Moment }, in moment order.
function MovePresentationTypes.TemplateRefs(presentation: Presentation?): { { Name: string, Moment: string } }
	local refs = {}
	if presentation == nil then
		return refs
	end
	for _, moment in MovePresentationTypes.Moments do
		local cue = presentation[moment.Name]
		if cue and cue.Template then
			table.insert(refs, { Name = cue.Template, Moment = moment.Name })
		end
	end
	return refs
end

-- The catalogue wire contract ---------------------------------------------------------------------------

MovePresentationTypes.Network = {
	RemoteNames = {
		-- Server -> client: a Snapshot (the answer to Request) or a Delta (to every client, on an edit).
		Catalog = "MovePresentation_Catalog",
		-- Client -> server, no payload: "send me a Snapshot". Fired once at start, and again only when a
		-- Delta arrives for a version this client does not have.
		Request = "MovePresentation_Request",
	},
	MaxRequestsPerSecond = 2,
}

export type CatalogMessage = {
	Kind: "Snapshot" | "Delta",
	Version: number,
	-- Delta only: the version this delta applies on top of.
	Base: number?,
	-- Snapshot: every move with a block. Delta: the moves whose block changed or appeared.
	Entries: { [string]: Presentation },
	-- Delta only: moves whose block went away (the move was deleted, or its block cleared).
	Removes: { string }?,
}

export type CatalogState = {
	Version: number,
	Entries: { [string]: Presentation },
}

export type ApplyResult = "Applied" | "Stale" | "Ignored"

-- Applies one catalogue message to a client's state, in place. PURE (no Instances), so the versioning
-- rules are specced directly:
--   * a Snapshot newer than what is held replaces everything ("Applied"); an older one is "Ignored"
--     (a Delta that overtook the Snapshot it followed already moved the state past it)
--   * a Delta whose Base is the held version applies ("Applied")
--   * a Delta whose Base is not: this client missed one. "Stale" -- the caller asks for a Snapshot.
--     A Delta at or below the held version (one the Snapshot already covered) is "Ignored".
-- Returns the result and every MoveId whose entry changed.
function MovePresentationTypes.ApplyCatalogMessage(
	state: CatalogState,
	message: CatalogMessage
): (ApplyResult, { string })
	local changed: { string } = {}
	if typeof(message) ~= "table" or typeof(message.Version) ~= "number" or typeof(message.Entries) ~= "table" then
		return "Ignored", changed
	end
	if message.Kind == "Snapshot" then
		if message.Version < state.Version then
			return "Ignored", changed
		end
		for moveId in state.Entries do
			if message.Entries[moveId] == nil then
				table.insert(changed, moveId)
			end
		end
		for moveId in message.Entries do
			table.insert(changed, moveId)
		end
		state.Entries = message.Entries
		state.Version = message.Version
		return "Applied", changed
	end
	if message.Kind ~= "Delta" then
		return "Ignored", changed
	end
	if message.Version <= state.Version then
		return "Ignored", changed
	end
	if message.Base ~= state.Version then
		return "Stale", changed
	end
	for moveId, presentation in message.Entries do
		state.Entries[moveId] = presentation
		table.insert(changed, moveId)
	end
	for _, moveId in message.Removes or {} do
		state.Entries[moveId] = nil
		table.insert(changed, moveId)
	end
	state.Version = message.Version
	return "Applied", changed
end

return MovePresentationTypes
