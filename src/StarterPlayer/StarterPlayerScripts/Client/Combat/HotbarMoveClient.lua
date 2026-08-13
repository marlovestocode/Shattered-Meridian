--!strict
--[[
	HotbarMoveClient.lua

	Owns: the ONE call site that turns "fire whatever is bound to hotbar slot N" into the
	Combat_RequestFireHotbarMove RemoteEvent -- shared by both ways a slot can be activated
	(Client/Combat/CombatClient.lua's HotbarSlot1-5 keybind branches, and
	Client/UI/Screens/HUD/init.lua's AbilitySlot OnActivated click handler) so the actual
	remote-call logic exists exactly once, per this feature's own "don't duplicate the remote-call
	logic" requirement.

	Fire(slot) is a plain lookup-then-FireServer, not a request/response round trip -- this mirrors
	CombatClient.lua's own fire-and-forget shape for every other combat action (RequestBasicAttack,
	RequestDash, ...) rather than MoveEditorSystem's RemoteFunction-based CRUD remotes, since this
	is fired from the same hot input path (a keypress) those remotes are. A genuine server-side
	reject (not an admin, on cooldown, move not found, ...) still reaches this client -- see
	CombatSystem.lua's handleFireHotbarMoveRequest -- over the existing Combat_ActionRejected
	channel CombatClient.lua already listens to and logs (Action = "CustomMove"); there is nothing
	for this module itself to roll back, since firing plays no local prediction (see
	Types.RejectedActionKind's own header on "CustomMove").

	Silently no-ops when nothing is bound to `slot` (Client/Combat/HotbarBindings.lua returns nil)
	rather than firing an empty request -- the server would reject an empty/invalid MoveId anyway,
	but there is no reason to spend a network call and a rate-limiter slot on a slot the admin never
	assigned. Does NOT check admin status locally -- see HotbarBindings.lua's own header for why a
	non-admin can never have anything bound to fire in the first place, and CombatSystem.lua's own
	AdminConfig re-check is the real gate regardless.

	Does not own: the binding store (HotbarBindings.lua), input capture (CombatClient.lua), or
	hotbar rendering (HUD/init.lua) -- this module is pure plumbing between the three.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local HotbarBindings = require(script.Parent.HotbarBindings)

local logger = Logger.scope("HotbarMoveClient")

local HotbarMoveClient = {}

local requestFireHotbarMoveRemote: RemoteEvent? = nil

-- Called once from Main.client.lua, before CombatClient.Start()/UI.Mount()'s HUD consumers can
-- possibly receive real input -- see that file's own boot-order comment. Mirrors every other
-- *Client.lua module's Start() shape in this codebase (obtain remotes once, up front) rather than
-- lazily resolving the remote on first Fire(), so a slow server boot fails loudly here instead of
-- silently inside the first player's first hotbar press.
function HotbarMoveClient.Start(): ()
	logger:debug("Waiting for Combat_RequestFireHotbarMove remote")
	requestFireHotbarMoveRemote = NetworkBridge.GetRemoteEvent(Constants.Combat.RemoteNames.RequestFireHotbarMove)
	logger:debug("Combat_RequestFireHotbarMove remote found")
end

-- Fires whatever MoveId is currently bound to `slot` (1-5) -- see file header. No-ops if nothing
-- is bound, or if Start() hasn't run yet (defensive; every real caller runs after Main.client.lua's
-- boot sequence has already called Start()).
function HotbarMoveClient.Fire(slot: number): ()
	local moveId = HotbarBindings.Get(slot)
	if not moveId then
		logger:debug("Hotbar slot press ignored -- nothing bound", { slot = slot })
		return
	end
	if not requestFireHotbarMoveRemote then
		logger:warn("HotbarMoveClient.Fire called before Start() -- ignoring", { slot = slot, moveId = moveId })
		return
	end

	logger:debug("FireServer", { action = "RequestFireHotbarMove", slot = slot, moveId = moveId })
	requestFireHotbarMoveRemote:FireServer(moveId)
end

return HotbarMoveClient
