--!strict
--[[
	DomainRules.lua

	Owns: the domain's RULE SEAM -- composing a realm's Rule entries into one resolved RuleSet per body,
	publishing that set as Humanoid Attributes, and the readers every consumer asks through. The one
	module both ends of the seam require: Server/Combat/Domain/DomainSystem.lua writes, and the layers the
	rules modify read.

	WHY ATTRIBUTES, AND WHY NO COMBAT LAYER REQUIRES DomainSystem. A domain changes how damage prices,
	whether a guard holds, how fast you move -- questions DamageSystem, DefenseSystem, AttackRequestSystem,
	RunSystem and ParkourSystem already answer. Reaching into each from a System that sits ABOVE all four
	combat layers would invert the stack (CLAUDE.md's combat-layering rule), and each of them requiring
	DomainSystem would be four new upward seams. So the realm publishes its resolved rules on each member's
	Humanoid -- the codebase's established cross-system seam (AttributeConstants' header; RunSystem's whole
	resolver is built this way) -- and each consumer reads the ONE number or flag its own question needs,
	through this module, the same way DefenseSystem reads HitstunUntil and AirHeldUntil without requiring
	the systems that set them. Humanoid Attributes also replicate for free, so the member's own client
	reads the same set for its predicted gates (the parkour combat gate, the realm's UI) with no remote.

	A DEADLINE, NOT A FLAG (AttributeConstants' CombatBusyUntil reasoning). Every rule attribute is read
	through DomainUntil -- the governing realm's own scheduled end, on the shared server clock
	(workspace:GetServerTimeNow(), the one clock a client can compare against too). DomainSystem clears the
	set the moment a body leaves or a realm ends; if it ever fails to, the rules still lapse on their own
	at the time the realm was always going to end, rather than stranding a player slowed forever.

	COMPOSITION. Several realms can govern one body at once (Coexist, a Contest). Scales multiply; flags
	OR; sealed moves union. A contested realm's scales are pulled toward 1 by its ContestScale (a 0.5
	contest halves a 2x damage rule to 1.5x); its flags still hold -- a seal cannot be half-applied.

	WHAT READS WHAT (keep this list true -- it is the whole integration surface):
	  DamageDealt / DamageTaken / GuardDamageTaken / HitstunTaken   DamageSystem.applyOutcome
	  NoBlock / NoParry                                            DefenseSystem pass 1
	  NoEvade                                                      DefenseSystem.BeginEvade, ParkourSystem
	  Cooldown / SealMove / SealArts / SealProjectiles / SealDomains  AttackRequestSystem.throw
	  MoveSpeed / Rooted                                           RunSystem
	  NoParkour                                                    ParkourSystem, Client/Parkour (context)
	  DomainOwnedUntil (not a rule: "this body's own realm is up")  AttackRequestSystem.throw

	Does not own: which rules a realm has (DomainTypes), who is a member (DomainSystem), or what any
	consumer does with the answer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)

local DomainRules = {}

export type Flag =
	"SealArts"
	| "SealProjectiles"
	| "SealDomains"
	| "NoBlock"
	| "NoParry"
	| "NoEvade"
	| "NoParkour"
	| "Rooted"

export type ScaleKind = "DamageDealt" | "DamageTaken" | "GuardDamageTaken" | "HitstunTaken" | "MoveSpeed" | "Cooldown"

export type RuleSet = {
	DamageDealt: number,
	DamageTaken: number,
	GuardDamageTaken: number,
	HitstunTaken: number,
	MoveSpeed: number,
	Cooldown: number,
	Flags: number,
	-- MoveId -> true.
	SealedMoves: { [string]: boolean },
}

-- One bit per flag. The order is the wire format of the DomainFlags Attribute -- append, never reorder.
local FLAG_BITS: { [string]: number } = {
	SealArts = 1,
	SealProjectiles = 2,
	SealDomains = 4,
	NoBlock = 8,
	NoParry = 16,
	NoEvade = 32,
	NoParkour = 64,
	Rooted = 128,
}
DomainRules.FlagBits = FLAG_BITS

local SCALE_ATTRIBUTES: { [string]: string } = {
	DamageDealt = AttributeConstants.DomainDamageDealt,
	DamageTaken = AttributeConstants.DomainDamageTaken,
	GuardDamageTaken = AttributeConstants.DomainGuardDamageTaken,
	HitstunTaken = AttributeConstants.DomainHitstunTaken,
	MoveSpeed = AttributeConstants.DomainMoveSpeed,
	Cooldown = AttributeConstants.DomainCooldown,
}
local SCALE_KINDS = { "DamageDealt", "DamageTaken", "GuardDamageTaken", "HitstunTaken", "MoveSpeed", "Cooldown" }

-- Every Attribute this module writes -- RunSystem mirrors exactly these, and Clear removes exactly these.
DomainRules.Attributes = {
	AttributeConstants.DomainUntil,
	AttributeConstants.DomainGovernor,
	AttributeConstants.DomainFlags,
	AttributeConstants.DomainSealedMoves,
	AttributeConstants.DomainDamageDealt,
	AttributeConstants.DomainDamageTaken,
	AttributeConstants.DomainGuardDamageTaken,
	AttributeConstants.DomainHitstunTaken,
	AttributeConstants.DomainMoveSpeed,
	AttributeConstants.DomainCooldown,
}

-- The realm's clock: the one both machines share. A caller that has its own synthetic clock (a spec)
-- passes `now` explicitly everywhere below.
function DomainRules.ServerNow(): number
	return Workspace:GetServerTimeNow()
end

-- Composing ----------------------------------------------------------------------------------------------

function DomainRules.Empty(): RuleSet
	return {
		DamageDealt = 1,
		DamageTaken = 1,
		GuardDamageTaken = 1,
		HitstunTaken = 1,
		MoveSpeed = 1,
		Cooldown = 1,
		Flags = 0,
		SealedMoves = {},
	}
end

-- Folds one authored Rule into `set`. `contestScale` (1 for an uncontested realm) pulls a scale toward 1.
function DomainRules.Apply(set: RuleSet, kind: string, value: number, moveId: string?, contestScale: number?): ()
	local scale = contestScale or 1
	if SCALE_ATTRIBUTES[kind] then
		local effective = 1 + (value - 1) * scale
		local current = (set :: any)[kind] :: number
		(set :: any)[kind] = current * math.max(effective, 0)
		return
	end
	if kind == "SealMove" then
		if moveId and moveId ~= "" then
			set.SealedMoves[moveId] = true
		end
		return
	end
	local bit = FLAG_BITS[kind]
	if bit then
		set.Flags = bit32.bor(set.Flags, bit)
	end
end

function DomainRules.IsEmpty(set: RuleSet): boolean
	if set.Flags ~= 0 or next(set.SealedMoves) ~= nil then
		return false
	end
	for _, kind in SCALE_KINDS do
		if (set :: any)[kind] ~= 1 then
			return false
		end
	end
	return true
end

-- The sealed-move set as the Attribute carries it: ",a,b," -- delimited at both ends so a lookup is one
-- plain find for ",<id>," and can never match a prefix of a longer id.
local function encodeSealed(sealed: { [string]: boolean }): string
	local ids: { string } = {}
	for id in sealed do
		table.insert(ids, id)
	end
	if #ids == 0 then
		return ""
	end
	table.sort(ids)
	return "," .. table.concat(ids, ",") .. ","
end

-- Publishing ---------------------------------------------------------------------------------------------

-- Writes `set` onto `humanoid`, valid until `until_` (server time), governed by realm `governor`. Writes
-- only what changed: every SetAttribute here replicates to every client, and a membership pass restating
-- an unchanged set ten times a second would be ten round trips of nothing per member.
function DomainRules.Publish(humanoid: Humanoid, set: RuleSet, until_: number, governor: string): ()
	local function write(name: string, value: any): ()
		if humanoid:GetAttribute(name) ~= value then
			humanoid:SetAttribute(name, value)
		end
	end
	for _, kind in SCALE_KINDS do
		local value = (set :: any)[kind] :: number
		-- 1 is "no change", and is published as absent so a body under a realm that only seals a move
		-- carries one Attribute rather than seven.
		write(SCALE_ATTRIBUTES[kind], if value == 1 then nil else value)
	end
	write(AttributeConstants.DomainFlags, if set.Flags == 0 then nil else set.Flags)
	local sealed = encodeSealed(set.SealedMoves)
	write(AttributeConstants.DomainSealedMoves, if sealed == "" then nil else sealed)
	write(AttributeConstants.DomainGovernor, governor)
	write(AttributeConstants.DomainUntil, until_)
end

-- Removes every rule attribute. Idempotent, and cheap on a body that carries none.
function DomainRules.Clear(humanoid: Humanoid): ()
	for _, name in DomainRules.Attributes do
		if humanoid:GetAttribute(name) ~= nil then
			humanoid:SetAttribute(name, nil)
		end
	end
end

-- Stamps / clears the owner-side lease: "this body's own realm is up until then".
function DomainRules.SetOwned(humanoid: Humanoid, until_: number?): ()
	if humanoid:GetAttribute(AttributeConstants.DomainOwnedUntil) ~= until_ then
		humanoid:SetAttribute(AttributeConstants.DomainOwnedUntil, until_)
	end
end

-- Reading ------------------------------------------------------------------------------------------------

local function numberAttribute(humanoid: Humanoid, name: string, default: number): number
	local value = humanoid:GetAttribute(name)
	if typeof(value) ~= "number" or value ~= value then
		return default
	end
	return value
end

-- Whether a realm's rules currently govern this body. Every reader below asks this first, so a set whose
-- lease has passed reads as nothing at all.
function DomainRules.IsGoverned(humanoid: Humanoid, now: number?): boolean
	local until_ = humanoid:GetAttribute(AttributeConstants.DomainUntil)
	if typeof(until_) ~= "number" then
		return false
	end
	return until_ > (now or DomainRules.ServerNow())
end

-- A scale rule's live value: 1 when nothing governs the body or the realm does not touch it.
function DomainRules.Scale(humanoid: Humanoid?, kind: ScaleKind, now: number?): number
	if humanoid == nil or not DomainRules.IsGoverned(humanoid, now) then
		return 1
	end
	local attribute = SCALE_ATTRIBUTES[kind]
	return math.max(numberAttribute(humanoid, attribute, 1), 0)
end

function DomainRules.Has(humanoid: Humanoid?, flag: Flag, now: number?): boolean
	if humanoid == nil or not DomainRules.IsGoverned(humanoid, now) then
		return false
	end
	local flags = math.floor(numberAttribute(humanoid, AttributeConstants.DomainFlags, 0))
	return bit32.band(flags, FLAG_BITS[flag]) ~= 0
end

export type MoveTraits = {
	IsArt: boolean?,
	IsProjectile: boolean?,
	IsDomain: boolean?,
}

-- Whether a realm governing this body forbids throwing `moveId`. Traits are what the attack layer already
-- knows about the move it resolved, so the three category seals need no registry lookup here.
function DomainRules.IsSealed(humanoid: Humanoid?, moveId: string, traits: MoveTraits, now: number?): boolean
	if humanoid == nil or not DomainRules.IsGoverned(humanoid, now) then
		return false
	end
	local flags = math.floor(numberAttribute(humanoid, AttributeConstants.DomainFlags, 0))
	if traits.IsArt and bit32.band(flags, FLAG_BITS.SealArts) ~= 0 then
		return true
	end
	if traits.IsProjectile and bit32.band(flags, FLAG_BITS.SealProjectiles) ~= 0 then
		return true
	end
	if traits.IsDomain and bit32.band(flags, FLAG_BITS.SealDomains) ~= 0 then
		return true
	end
	local sealed = humanoid:GetAttribute(AttributeConstants.DomainSealedMoves)
	if typeof(sealed) == "string" and sealed ~= "" then
		return string.find(sealed, "," .. moveId .. ",", 1, true) ~= nil
	end
	return false
end

-- The realm id governing this body, for presentation (whose law am I under). nil when nothing is.
function DomainRules.GovernorOf(humanoid: Humanoid?, now: number?): string?
	if humanoid == nil or not DomainRules.IsGoverned(humanoid, now) then
		return nil
	end
	local governor = humanoid:GetAttribute(AttributeConstants.DomainGovernor)
	return if typeof(governor) == "string" and governor ~= "" then governor else nil
end

-- Whether this body's OWN realm is still up -- the attack layer refuses a second domain cast while it is.
function DomainRules.OwnsLiveDomain(humanoid: Humanoid?, now: number?): boolean
	if humanoid == nil then
		return false
	end
	local until_ = humanoid:GetAttribute(AttributeConstants.DomainOwnedUntil)
	return typeof(until_) == "number" and until_ > (now or DomainRules.ServerNow())
end

-- The whole resolved set as it currently reads -- for the specs, the realm's UI and debugging. nil when
-- nothing governs the body.
function DomainRules.Read(humanoid: Humanoid, now: number?): RuleSet?
	if not DomainRules.IsGoverned(humanoid, now) then
		return nil
	end
	local set = DomainRules.Empty()
	for _, kind in SCALE_KINDS do
		(set :: any)[kind] = numberAttribute(humanoid, SCALE_ATTRIBUTES[kind], 1)
	end
	set.Flags = math.floor(numberAttribute(humanoid, AttributeConstants.DomainFlags, 0))
	local sealed = humanoid:GetAttribute(AttributeConstants.DomainSealedMoves)
	if typeof(sealed) == "string" then
		for id in string.gmatch(sealed, "[^,]+") do
			set.SealedMoves[id] = true
		end
	end
	return set
end

return DomainRules
