--!strict
--[[
	ConstantsValidation.lua

	Owns: shape validation for Constants.Combat's hand-authored attack data --
	engineering-standards.md's "validate at every external boundary" applied to Constants.lua
	itself: it's edited by hand, not generated, so a future restructure (or a stale merge) could
	silently drop a field a request handler relies on. Every field checked here is one
	CombatSystem.lua's selectAttackDefinition/handleAttackRequest actually reads; if this validation
	ever needs to be updated, it's because those call sites started reading something new, not the
	other way around.

	Moved out of CombatSystem.lua (Chief Architect's decomposition audit) to ReplicatedStorage/Shared
	as its own module: validating a hand-authored data table's shape has nothing to do with combat
	resolution, needs nothing CombatSystem.lua owns (no CombatState, no remotes, no Player), and
	shouldn't require touching that file to test independently. CombatSystem.Init() calls
	ValidateCombatConstants() once, before creating any remote -- a failure aborts Init() entirely (no
	remotes, no handlers) rather than letting the first real attack request hit nil arithmetic deep in
	hit resolution.

	Does not own: what happens when validation fails (CombatSystem.Init() decides that), or any
	Constants field validation outside Constants.Combat.Weapons/Hitboxes -- this module's scope is
	exactly what CombatSystem.lua's own attack-selection path reads.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("ConstantsValidation")

local ConstantsValidation = {}

local REQUIRED_DEFINITION_NUMBER_FIELDS =
	{ "WindupSeconds", "ActiveSeconds", "RecoverySeconds", "Damage", "PostureDamage", "Cooldown" }

function ConstantsValidation.ValidateAttackDefinition(category: string, index: number, definition: unknown): boolean
	if typeof(definition) ~= "table" then
		logger:error("Invalid Constants.Combat.Hitboxes entry: not a table", { category = category, index = index })
		return false
	end

	local candidate = definition :: { [string]: unknown }
	local ok = true

	if typeof(candidate.DebugName) ~= "string" then
		logger:error("Invalid hitbox definition: DebugName missing/non-string", { category = category, index = index })
		ok = false
	end
	if typeof(candidate.Size) ~= "Vector3" then
		logger:error("Invalid hitbox definition: Size is not a Vector3", { category = category, index = index })
		ok = false
	end
	if typeof(candidate.Offset) ~= "CFrame" then
		logger:error("Invalid hitbox definition: Offset is not a CFrame", { category = category, index = index })
		ok = false
	end
	for _, field in ipairs(REQUIRED_DEFINITION_NUMBER_FIELDS) do
		if typeof(candidate[field]) ~= "number" then
			logger:error(
				"Invalid hitbox definition: field missing/non-numeric",
				{ category = category, index = index, field = field }
			)
			ok = false
		end
	end

	return ok
end

function ConstantsValidation.ValidateAttackCategory(category: string, stages: unknown): boolean
	if typeof(stages) ~= "table" or #(stages :: { unknown }) == 0 then
		logger:error("Constants.Combat.Hitboxes." .. category .. " is missing or empty", {})
		return false
	end

	local ok = true
	for index, definition in ipairs(stages :: { unknown }) do
		if not ConstantsValidation.ValidateAttackDefinition(category, index, definition) then
			ok = false
		end
	end
	return ok
end

-- If this ever fails, it means CombatSystem.lua's read side (selectAttackDefinition,
-- Constants.Combat.Weapons[weaponId].Stages) and Constants.lua's data side have drifted apart. The
-- fix is to bring them back in sync (update whichever side is stale), never to silently let request
-- handlers run against missing data.
--
-- One weapon's Basic/Heavy staged arrays + single Finisher definition (Constants.Combat.
-- Weapons[weaponId].Stages) -- reuses ValidateAttackCategory/ValidateAttackDefinition above,
-- namespaced per weapon so a validation failure's log message says which weapon drifted.
function ConstantsValidation.ValidateWeapon(weaponId: string, weaponData: unknown): boolean
	if typeof(weaponData) ~= "table" then
		logger:error("Invalid Constants.Combat.Weapons entry: not a table", { weaponId = weaponId })
		return false
	end
	local stages = (weaponData :: { [string]: unknown }).Stages
	if typeof(stages) ~= "table" then
		logger:error("Constants.Combat.Weapons." .. weaponId .. ".Stages is missing", {})
		return false
	end
	local stagesTable = stages :: { [string]: unknown }

	local basicOk = ConstantsValidation.ValidateAttackCategory(weaponId .. ".Basic", stagesTable.Basic)
	local heavyOk = ConstantsValidation.ValidateAttackCategory(weaponId .. ".Heavy", stagesTable.Heavy)
	-- The finisher is a single definition, not a staged array (handleAttackRequest reads
	-- Stages.Finisher directly), so it's validated as one definition rather than a category.
	local finisherOk = ConstantsValidation.ValidateAttackDefinition(weaponId .. ".Finisher", 1, stagesTable.Finisher)

	return basicOk and heavyOk and finisherOk
end

-- Runs once at CombatSystem.Init(), before any remote is created -- a failure here means Init()
-- aborts entirely (no remotes, no handlers) rather than letting the first real attack request hit
-- nil arithmetic deep in hit resolution. Takes the live Constants.Combat table directly (rather than
-- requiring Constants.lua itself) so a test can hand it a deliberately-broken fixture without
-- needing to mutate the real Constants module.
function ConstantsValidation.ValidateCombatConstants(combatConstants: { [string]: unknown }): boolean
	local weapons = combatConstants.Weapons
	if typeof(weapons) ~= "table" then
		logger:error(
			"Constants.Combat.Weapons is missing -- CombatSystem.lua reads per-stage attack data from "
				.. "Constants.Combat.Weapons[weaponId].Stages.Basic/Heavy/Finisher, not a flat Hitboxes."
				.. "Basic/Heavy table. Fix Constants.lua (or CombatSystem.lua if it's the one that drifted) "
				.. "before this System can safely accept any attack request.",
			{}
		)
		return false
	end
	local weaponsTable = weapons :: { [string]: unknown }

	local primaryOk = ConstantsValidation.ValidateWeapon("Primary", weaponsTable.Primary)
	local secondaryOk = ConstantsValidation.ValidateWeapon("Secondary", weaponsTable.Secondary)
	local defaultWeaponOk = weaponsTable.Default == "Primary" or weaponsTable.Default == "Secondary"
	if not defaultWeaponOk then
		logger:error("Constants.Combat.Weapons.Default missing/invalid or doesn't name a real weapon", {})
	end
	local swapCooldownOk = typeof(weaponsTable.SwapCooldownSeconds) == "number"
		and (weaponsTable.SwapCooldownSeconds :: number) >= 0
	if not swapCooldownOk then
		logger:error("Constants.Combat.Weapons.SwapCooldownSeconds missing/invalid", {})
	end

	local hitboxes = combatConstants.Hitboxes
	if typeof(hitboxes) ~= "table" then
		logger:error("Constants.Combat.Hitboxes (geometry/sampling table) is missing", {})
		return false
	end
	local hitboxesTable = hitboxes :: { [string]: unknown }

	local sampleRateOk = typeof(hitboxesTable.SampleRate) == "number" and (hitboxesTable.SampleRate :: number) > 0
	if not sampleRateOk then
		logger:error("Constants.Combat.Hitboxes.SampleRate missing/invalid", {})
	end
	local maxSamplesOk = typeof(hitboxesTable.MaxSamplesPerSwing) == "number"
		and (hitboxesTable.MaxSamplesPerSwing :: number) > 0
	if not maxSamplesOk then
		logger:error("Constants.Combat.Hitboxes.MaxSamplesPerSwing missing/invalid", {})
	end
	local maxCandidateRadiusOk = typeof(hitboxesTable.MaxCandidateRadius) == "number"
		and (hitboxesTable.MaxCandidateRadius :: number) > 0
	if not maxCandidateRadiusOk then
		logger:error("Constants.Combat.Hitboxes.MaxCandidateRadius missing/invalid", {})
	end
	local combatEngagementRangeOk = typeof(combatConstants.CombatEngagementRange) == "number"
		and (combatConstants.CombatEngagementRange :: number) > 0
	if not combatEngagementRangeOk then
		logger:error("Constants.Combat.CombatEngagementRange missing/invalid", {})
	end
	local maxTrackedOpponentsOk = typeof(combatConstants.MaxTrackedOpponents) == "number"
		and (combatConstants.MaxTrackedOpponents :: number) > 0
	if not maxTrackedOpponentsOk then
		logger:error("Constants.Combat.MaxTrackedOpponents missing/invalid", {})
	end
	local sweepSubstepsOk = typeof(hitboxesTable.SweepSubsteps) == "number"
		and (hitboxesTable.SweepSubsteps :: number) > 0
	if not sweepSubstepsOk then
		logger:error("Constants.Combat.Hitboxes.SweepSubsteps missing/invalid", {})
	end
	local maxPartsPerQueryOk = typeof(hitboxesTable.MaxPartsPerQuery) == "number"
		and (hitboxesTable.MaxPartsPerQuery :: number) > 0
	if not maxPartsPerQueryOk then
		logger:error("Constants.Combat.Hitboxes.MaxPartsPerQuery missing/invalid", {})
	end

	local ok = primaryOk
		and secondaryOk
		and defaultWeaponOk
		and swapCooldownOk
		and sampleRateOk
		and maxSamplesOk
		and maxCandidateRadiusOk
		and combatEngagementRangeOk
		and maxTrackedOpponentsOk
		and sweepSubstepsOk
		and maxPartsPerQueryOk
	if ok then
		local primaryWeapon = weaponsTable.Primary :: { Stages: { Basic: { unknown }, Heavy: { unknown } } }
		local secondaryWeapon = weaponsTable.Secondary :: { Stages: { Basic: { unknown }, Heavy: { unknown } } }
		logger:info("Combat constants validated", {
			primaryBasicStages = #primaryWeapon.Stages.Basic,
			primaryHeavyStages = #primaryWeapon.Stages.Heavy,
			secondaryBasicStages = #secondaryWeapon.Stages.Basic,
			secondaryHeavyStages = #secondaryWeapon.Stages.Heavy,
			sampleRate = hitboxesTable.SampleRate,
		})
	end
	return ok
end

return ConstantsValidation
