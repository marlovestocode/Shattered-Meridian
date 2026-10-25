--!strict
-- KitValidation, RaceManager.Validate and BloodlineManager.Validate, old against new. The Legacy fixtures under
-- Tests/Fixtures are the hand-written `typeof` validators exactly as they stood before they were declared as Schema
-- shapes (2026-10-25, W4). Both run over one corpus -- a valid record of each kind, and EVERY single-field corruption of
-- it at every depth (nil, NaN, +-inf, wrong type, empty and oversize strings, empty tables, an unknown enum word) -- and
-- must return the same value or the same error code. The frozen copies are deleted when this spec is.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BloodlineManager = require(ServerScriptService.Server.Managers.BloodlineManager)
local BloodlineLegacy = require(ServerScriptService.Tests.Fixtures.BloodlineValidateLegacy)
local KitValidation = require(ReplicatedStorage.Shared.Kit.KitValidation)
local KitValidationLegacy = require(ServerScriptService.Tests.Fixtures.KitValidationLegacy)
local RaceManager = require(ServerScriptService.Server.Managers.RaceManager)
local RaceLegacy = require(ServerScriptService.Tests.Fixtures.RaceValidateLegacy)

local NAN = 0 / 0
local INF = math.huge

local function same(a: any, b: any): boolean
	if a == b then
		return true
	end
	if typeof(a) == "number" and typeof(b) == "number" then
		return a ~= a and b ~= b
	end
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not same(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil and b[key] ~= nil then
			return false
		end
	end
	return true
end

local HOSTILE: { any } = {
	NAN,
	INF,
	-INF,
	-1,
	0,
	1e9,
	"",
	"Nope",
	string.rep("q", 3000),
	true,
	false,
	{},
	{ {} },
	{ 1, 2 },
	Vector3.zero,
}

-- Valid building blocks -------------------------------------------------------------------------------------

local function effects(): { { [string]: any } }
	return {
		{ Kind = "AttributeDelta", Lifetime = "Timed", AttributeKey = "Might", Delta = 2, DurationSeconds = 5 },
		{ Kind = "Tag", Lifetime = "Instant", Tag = "Marked", Magnitude = 1 },
		{ Kind = "QiRestore", Lifetime = "Bound", QiRestoreAmount = 10 },
	}
end

local function ability(): { [string]: any }
	return {
		Id = "ability-one",
		DisplayName = "Ability",
		Description = "does a thing",
		Kind = "Active",
		CooldownSeconds = 4,
		QiCost = 10,
		Effects = effects(),
	}
end

local function trait(): { [string]: any }
	return { TraitId = "trait-one", RaceId = "Human", RequiredTier = 2, Ability = ability() }
end

local function bloodline(): { [string]: any }
	return {
		BloodlineId = "line-one",
		DisplayName = "Line",
		RarityTier = "Rare",
		FlavorText = "flavour",
		NativeRaceId = "Firmborn",
		AwakeningCondition = { Kind = "KillCount", Params = { Needed = 3, Window = 60 } },
		Stages = {
			{ StageIndex = 1, DisplayName = "First", PassiveEffects = effects(), GrantedAbility = ability() },
			{ StageIndex = 2, DisplayName = "Second", PassiveEffects = {} },
		},
	}
end

-- Every single-field corruption of `value`, at every depth of plain tables: replaced by each hostile value, and removed.
local function corruptions(value: { [string]: any }): { any }
	local out: { any } = { value }

	local function walk(path: { any })
		local function rebuilt(replacement: any, removeIt: boolean): any
			local copy = table.clone(value)
			local cursor: any = copy
			for index, key in path do
				if index == #path then
					cursor[key] = if removeIt then nil else replacement
				else
					cursor[key] = table.clone(cursor[key])
					cursor = cursor[key]
				end
			end
			return copy
		end

		for _, bad in HOSTILE do
			table.insert(out, rebuilt(bad, false))
		end
		table.insert(out, rebuilt(nil, true))

		-- Recurse into the value at `path` when it is a plain table.
		local node: any = value
		for _, key in path do
			node = node[key]
		end
		if typeof(node) == "table" then
			for key in node do
				local deeper = table.clone(path)
				table.insert(deeper, key)
				walk(deeper)
			end
		end
	end

	for key in value do
		walk({ key })
	end
	for _, bad in HOSTILE do
		table.insert(out, bad)
	end
	return out
end

local function agree(
	oldFn: (any) -> (any, string?),
	newFn: (any) -> (any, string?),
	cases: { any },
	label: string
): (number, number)
	local accepted = 0
	for index, case in cases do
		local oldValue, oldError = oldFn(case)
		local newValue, newError = newFn(case)
		if oldError ~= newError or not same(oldValue, newValue) then
			error(
				`{label} disagrees on corpus case {index}: old error {tostring(oldError)}, new error {tostring(newError)}`
			)
		end
		if oldError == nil then
			accepted += 1
		end
	end
	return accepted, #cases
end

return function()
	-- The corpus must reach the accepting branch (and, being full of corruptions, the rejecting one) or agreement
	-- proves nothing.
	local function check(oldFn: any, newFn: any, cases: { any }, label: string)
		local accepted, total = agree(oldFn, newFn, cases, label)
		expect(accepted > 0).to.equal(true)
		expect(accepted < total).to.equal(true)
	end

	describe("KitValidation, old against new", function()
		it("ValidateModifierSpec agrees on every corruption of each effect kind", function()
			for _, effect in effects() do
				check(
					KitValidationLegacy.ValidateModifierSpec,
					KitValidation.ValidateModifierSpec,
					corruptions(effect),
					"ValidateModifierSpec"
				)
			end
		end)

		it("ValidateEffects agrees", function()
			check(
				KitValidationLegacy.ValidateEffects,
				KitValidation.ValidateEffects,
				corruptions(effects() :: any),
				"ValidateEffects"
			)
		end)

		it("ValidateAbility agrees", function()
			check(
				KitValidationLegacy.ValidateAbility,
				KitValidation.ValidateAbility,
				corruptions(ability()),
				"ValidateAbility"
			)
		end)
	end)

	describe("RaceManager.Validate, old against new", function()
		it("agrees on every corruption of a trait", function()
			check(RaceLegacy.Validate, RaceManager.Validate, corruptions(trait()), "RaceManager.Validate")
		end)
	end)

	describe("BloodlineManager.Validate, old against new", function()
		it("agrees on every corruption of a bloodline", function()
			check(
				BloodlineLegacy.Validate,
				BloodlineManager.Validate,
				corruptions(bloodline()),
				"BloodlineManager.Validate"
			)
		end)
	end)
end
