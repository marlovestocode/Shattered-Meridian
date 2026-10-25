--!strict
--[[
	CombatHarness.lua

	Owns: the two things every combat spec does around a body -- register it with the layers that need to know
	it exists, and put every layer back to empty afterwards. Nine specs each chained four to eight
	`X.Reset()` calls in an order of their own, and twenty built the body by hand; the cohesion audit found
	that "a combatant nobody registered with one layer" and "a reset that missed a layer" were most of the
	red tests it classed as fixture drift.

	RESET FOLLOWS CombatTick.PHASES. `Reset()` walks PHASES and calls the reset registered against each name,
	so the order is the frame order and a new phase cannot be added to CombatTick without this file knowing
	(Reset asserts every phase has a reset and CombatHarness.spec fails on a phase it does not cover).
	It is safe in that order, not only in the old top-down one: every subscription a layer holds on another is
	a CallbackList disconnect, which is idempotent after the owner's `:Clear()`, and every layer's Reset
	documents that it never depends on the Instances it is discarding still being valid.
	ParryWindows is Shared state the defense layer reads, so its reset rides with DefenseSystem's.

	WHAT IT NEVER DOES TO WEAPONS. `WeaponFixture` is VM-wide state installed once per spec file at collection
	time and never removed (a per-test Install/Remove tears the roster out from under the next file; see its
	header). Reset therefore touches no part of it -- not Install, not Remove, not Rebuild -- and Combatant only
	READS a weapon id the spec took from `WeaponFixture.Install()` itself.

	WHAT A SPEC KEEPS FOR ITSELF. Reset covers the combat layers in PHASES. A spec's own extras
	(AttackCatalog.Reset, DomainEffects.ResetForTesting, KnockbackAudit.Reset, a per-file registry) stay in
	that spec's afterEach, after `CombatHarness.Reset()`.

	THE BODY. `Combatant(body, options)` registers an existing Rig body. `Spawner(options)` binds those
	options once and returns `(name, position, lookAt?, anchored?) -> Dummy`, the shape the specs' private
	`makeDummy` all had, so a spec's layer set is one declaration at its top instead of a builder body.
	Layers are opt-OUT per spec because the specs genuinely differ (HitboxEngine.spec registers with the
	engine alone, DomainSystem.spec only tracks the body for realms) and a harness that registered more than
	the spec did before would change what its assertions see.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CombatTick = require(ServerScriptService.Server.Combat.CombatTick)
local AirComboSystem = require(ServerScriptService.Server.Combat.AirCombo.AirComboSystem)
local AttackRequestSystem = require(ServerScriptService.Server.Combat.Attack.AttackRequestSystem)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local DomainSystem = require(ServerScriptService.Server.Combat.Domain.DomainSystem)
local EngagementSystem = require(ServerScriptService.Server.Combat.Engagement.EngagementSystem)
local EnvironmentReactionSystem = require(ServerScriptService.Server.Combat.Environment.EnvironmentReactionSystem)
local GrabSystem = require(ServerScriptService.Server.Combat.Grab.GrabSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local SwingSequencer = require(ServerScriptService.Server.Combat.Attack.SwingSequencer)
local Rig = require(script.Parent.Rig)

local CombatHarness = {}

export type Dummy = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	-- HitboxEngine's combatant id, or nil when the spec's layer set leaves the engine out.
	Id: number?,
}

export type Layers = {
	-- Register with HitboxEngine. Default true.
	Engine: boolean?,
	-- Register with DefenseSystem (needs Engine). Default true.
	Defense: boolean?,
	-- The clip id DefenseSystem registers the body's parry window against.
	ParryAnimation: string?,
	-- Arm the body in SwingSequencer with this weapon id, as a live character is. Default: empty-handed.
	Weapon: string?,
	-- DomainSystem.TrackCombatantForTesting. Default false.
	Domain: boolean?,
	-- Build a real R6 rig (Rig.R6) instead of the bare Dummy. Default false.
	R6: boolean?,
}

-- One reset per CombatTick phase. Keyed by phase NAME so PHASES order, not this table's, decides the order.
local RESETS: { [string]: () -> () } = {
	HitboxEngine = HitboxEngine.Reset,
	DefenseSystem = function()
		DefenseSystem.Reset()
		ParryWindows.Reset()
	end,
	DamageSystem = DamageSystem.Reset,
	AttackRequestSystem = AttackRequestSystem.Reset,
	GrabSystem = GrabSystem.Reset,
	AirComboSystem = AirComboSystem.Reset,
	EngagementSystem = EngagementSystem.Reset,
	EnvironmentReactionSystem = EnvironmentReactionSystem.Reset,
	DomainSystem = DomainSystem.Reset,
}

-- Every combat layer back to empty, in frame order. Does not destroy Instances (that is Teardown) and does not
-- touch WeaponFixture (see the header).
function CombatHarness.Reset(): ()
	for _, phase in CombatTick.PHASES do
		local reset = RESETS[phase]
		assert(reset ~= nil, `CombatHarness.Reset: no reset for CombatTick phase "{phase}" -- add it to RESETS`)
		reset()
	end
end

-- Reset, then destroy every Rig-built or Rig-tracked Instance: the order every spec's afterEach used.
function CombatHarness.Teardown(): ()
	CombatHarness.Reset()
	Rig.DestroyAll()
end

-- Registers `body` with the layers `layers` names. Returns the engine's combatant id, or nil with no engine.
function CombatHarness.Combatant(body: Rig.Body, layers: Layers?): number?
	local options: Layers = layers or {}
	local id: number? = nil
	if options.Engine ~= false then
		id = HitboxEngine.RegisterCombatant(body.Model, body.Root, body.Humanoid)
		if options.Defense ~= false then
			DefenseSystem.RegisterCombatant(body.Model, body.Root, body.Humanoid, options.ParryAnimation)
		end
	end
	if options.Domain then
		DomainSystem.TrackCombatantForTesting(body.Model)
	end
	if options.Weapon then
		-- ARMED, because a fresh SwingSequencer record is EMPTY-HANDED and an unarmed combatant resolves
		-- no swings at all (see that module's own recordFor).
		SwingSequencer.SetWeapon(body.Model, options.Weapon, os.clock())
	end
	return id
end

-- `layers` bound once. The returned function builds a Rig.Dummy and registers it, with the argument order
-- every spec's private makeDummy used.
function CombatHarness.Spawner(layers: Layers?): (string, Vector3?, Vector3?, boolean?) -> Dummy
	return function(name: string, position: Vector3?, lookAt: Vector3?, anchored: boolean?): Dummy
		local body = if layers and layers.R6
			then Rig.R6(name, position, lookAt, anchored)
			else Rig.Dummy(name, position, lookAt, if anchored == nil then nil else { Anchored = anchored })
		local id = CombatHarness.Combatant(body, layers)
		return { Model = body.Model, Root = body.Root, Humanoid = body.Humanoid, Id = id }
	end
end

return CombatHarness
