--!strict
--[[
	ClientState.lua

	Owns: the client-side reflection of server-validated state that UI surfaces render from --
	Fusion Value objects only, never computed here. Per software-architecture.md's "server owns
	truth, client owns feel" principle and ui-ux-philosophy.md's HUD sync rule ("no optimistic HUD
	state that can visibly desync from actual outcomes"), every field below is written to
	exclusively by a NetworkBridge remote handler inside Bootstrap(), never by a component, a
	Screen, or any other client-side computation.

	Does not own: computing any of these values -- CombatSystem/TierSystem/etc. compute them
	server-side; this module only stores what the server has already told the client. Does not
	own purely cosmetic, non-gameplay local state either (a button's hover flicker, a menu's
	open/closed flag) -- that belongs as scope-local Values inside the component or Screen that
	owns the visual, not here.

	Health/MaxHealth/Posture/MaxPosture are now wired in Bootstrap() to
	CombatSystem's Combat_VitalsUpdated remote -- CombatSystem is no longer an empty Init(). Qi/MaxQi
	stay render-only defaults: no System owns the Qi resource yet (still not in
	software-architecture.md's ownership map, and CombatSystem's header is explicit that it doesn't
	track Qi), so wiring it now would mean fabricating data no server System produces -- the same
	reasoning this file documented for every field before CombatSystem existed, now narrowed to the
	one resource still waiting on its owning System. TierSystem/QiDeviationSystem/etc. remain empty
	Init()s, so this file has nothing else to wire yet.

	Second accepted pattern -- the Screen-returned handle: not every piece of server-reflected state
	belongs here. When a value has exactly one consumer and that consumer is a single Screen, routing
	it through this shared module would just add an indirection hop with no multi-consumer benefit to
	show for it -- so that state is instead kept as a Fusion.Value on the handle table the Screen's
	own Mount() returns, right next to (and following the same shape as) purely-cosmetic local state
	like a menu's open/closed flag. This file stays reserved for HUD-wide, multi-consumer vitals --
	the kind rendered by several independent components (VitalBar, DamageNumberLabel, etc.) that would
	otherwise each need their own remote listener. Existing examples of the Screen-returned-handle
	pattern, so a future Screen author has one place to look instead of re-deriving the choice from
	scratch: Screens/DevMenu/init.lua, Screens/CombatFeedback/init.lua, and Screens/Menus/init.lua's
	own IsOpen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("ClientState")

type Scope = Fusion.Scope<typeof(Fusion)>

export type ClientState = {
	-- Render-only defaults (a full bar looks correct before real data arrives) -- not balance
	-- numbers, and not a substitute for real values once TierSystem/CombatSystem exist.
	Health: Fusion.Value<number>,
	MaxHealth: Fusion.Value<number>,
	Posture: Fusion.Value<number>,
	MaxPosture: Fusion.Value<number>,
	-- Qi is a render-only default: no System owns the Qi resource yet (not in
	-- software-architecture.md's ownership map), so it follows the exact same render-only-default
	-- pattern Health/Posture used before CombatSystem existed, per docs/ui-ux-philosophy.md's
	-- Implementation Notes. Do not treat "the field exists" as "the resource is designed" -- a real
	-- owning System still needs to be designed and built before Bootstrap() wires it to anything.
	-- (Stamina was removed entirely -- Health and Posture are the game's only two combat vitals now.)
	Qi: Fusion.Value<number>,
	MaxQi: Fusion.Value<number>,
	-- Wired in Bootstrap() to CombatSystem's Combat_InCombatChanged remote -- unlike the vitals above,
	-- this is a boolean transition signal (see CombatState.inCombatUntil's own header), not a
	-- render-only default: it starts false and only ever reflects a real server-fired transition, so
	-- there is no "looks correct before real data arrives" concern here the way a full vitals bar has.
	InCombat: Fusion.Value<boolean>,
}

local ClientState = {}

function ClientState.new(scope: Scope): ClientState
	return {
		Health = scope:Value(100),
		MaxHealth = scope:Value(100),
		Posture = scope:Value(100),
		MaxPosture = scope:Value(100),
		Qi = scope:Value(100),
		MaxQi = scope:Value(100),
		InCombat = scope:Value(false),
	}
end

-- Runtime check on top of the Types.CombatVitalsPayload annotation, which Luau doesn't enforce at
-- the network boundary -- a malformed payload should be a clear, attributable warn log here, not a
-- confusing error deep inside a Fusion Value:set() call or a silently corrupted HUD bar.
local function isValidVitalsPayload(payload: unknown): boolean
	if typeof(payload) ~= "table" then
		return false
	end
	local candidate = payload :: { [string]: unknown }
	return typeof(candidate.Health) == "number"
		and typeof(candidate.MaxHealth) == "number"
		and typeof(candidate.Posture) == "number"
		and typeof(candidate.MaxPosture) == "number"
end

function ClientState.Bootstrap(state: ClientState): ()
	logger:debug("Waiting for Combat_VitalsUpdated remote")
	local vitalsUpdated = NetworkBridge.GetRemoteEvent(Constants.Combat.RemoteNames.VitalsUpdated)
	logger:debug("Combat_VitalsUpdated remote found")

	vitalsUpdated.OnClientEvent:Connect(function(payload: Types.CombatVitalsPayload)
		if not isValidVitalsPayload(payload) then
			logger:warn("Malformed Combat_VitalsUpdated payload ignored", { payload = tostring(payload) })
			return
		end

		logger:debug("Vitals payload received", {
			health = payload.Health,
			maxHealth = payload.MaxHealth,
			posture = payload.Posture,
			maxPosture = payload.MaxPosture,
		})

		state.Health:set(payload.Health)
		state.MaxHealth:set(payload.MaxHealth)
		state.Posture:set(payload.Posture)
		state.MaxPosture:set(payload.MaxPosture)
	end)

	logger:debug("Waiting for Combat_InCombatChanged remote")
	local inCombatChanged = NetworkBridge.GetRemoteEvent(Constants.Combat.RemoteNames.InCombatChanged)
	logger:debug("Combat_InCombatChanged remote found")

	inCombatChanged.OnClientEvent:Connect(function(payload: Types.InCombatPayload)
		if typeof(payload) ~= "table" or typeof(payload.InCombat) ~= "boolean" then
			logger:warn("Malformed Combat_InCombatChanged payload ignored", { payload = tostring(payload) })
			return
		end

		logger:debug("In-combat payload received", { inCombat = payload.InCombat })
		state.InCombat:set(payload.InCombat)
	end)
end

return ClientState
