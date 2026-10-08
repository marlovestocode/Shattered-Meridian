--!strict
--[[
	WeaponInventoryClient.lua

	Owns: listening to Weapon_InventoryChanged and handing what it says to the inventory HUD. That is
	the whole module -- it is the integration seam between one server push and one screen handle, the
	same shape Client/Blimp/BlimpController.lua keeps for CarriedResources.

	SENDS NOTHING. The two weapon keys (T draw/sheathe, Y select-next) belong to
	Client/Combat/AttackInputClient.lua, which already owns every combat keybind and already holds the
	remotes for them -- splitting one input layer across two modules by topic is how a keybind ends up
	handled twice. This module is receive-only.

	SAYS WHY A SWAP WAS REFUSED (2026-10-08). A draw, sheathe or switch the server refused under the swap rule
	(WeaponConstants.Swap) comes back as the unchanged inventory plus Refused and SwapReadyIn; this turns that
	into one Warning toast ("Weapon swap on cooldown -- 2.4s"), so the key never seems to just not work.

	DECIDES NOTHING EITHER. Which weapons are owned, which is selected and whether it is drawn are all
	server state (Server/Combat/Weapon/WeaponInventorySystem.lua); this renders the payload verbatim and
	keeps no copy of it. Nothing here can disagree with the server because nothing here remembers
	anything.

	Does not own: the panel's layout (UI/Screens/WeaponInventory/init.lua), the keys (AttackInputClient),
	or the inventory itself (the server).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)

local Notify = require(script.Parent.Parent.UI.Shell.Notify)
local WeaponInventoryModule = require(script.Parent.Parent.UI.Screens.WeaponInventory)

local logger = Logger.scope("WeaponInventoryClient")

local WeaponInventoryClient = {}

local started = false

-- Handed in by Main.client.lua from uiHandles.WeaponInventory, the same "screen exposes state, client
-- module drives it" split every other HUD-driving module here uses.
local hud: WeaponInventoryModule.WeaponInventoryHandle? = nil
local notify: Notify.NotifyHandle? = nil

-- What a refusal says, by the reason the server gave (AttackRequestSystem.RequestWeapon / CanAct). Anything not
-- listed reads as the generic line.
local REFUSAL_TEXT: { [string]: string } = {
	SwapCooldown = "Weapon swap on cooldown",
	Busy = "Can't swap mid-swing",
	Hitstun = "Can't swap while stunned",
	Staggered = "Can't swap while staggered",
	GuardBroken = "Can't swap while guard-broken",
	Guarding = "Can't swap while guarding",
	Grabbed = "Can't swap while grabbed",
	Grabbing = "Can't swap while holding someone",
	AirHeld = "Can't swap while held",
	Mounted = "Can't swap while mounted",
	ParkourAction = "Can't swap mid-traversal",
}

-- The toast for a refused swap. Pure, for its spec.
function WeaponInventoryClient.RefusalNotice(reason: string, readyIn: number?): (string, string?)
	local title = REFUSAL_TEXT[reason] or "Can't swap weapons right now"
	local detail = if typeof(readyIn) == "number" and readyIn > 0 then string.format("Ready in %.1fs", readyIn) else nil
	return title, detail
end

local function onInventoryChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: WeaponConstants.InventoryPayload
	if typeof(payload.Owned) ~= "table" then
		return
	end

	local refused = payload.Refused
	local channel = notify
	if typeof(refused) == "string" and channel then
		local title, detail = WeaponInventoryClient.RefusalNotice(refused, payload.SwapReadyIn)
		channel:Push({ Kind = "Warning", Title = title, Detail = detail })
	end

	local handle = hud
	if not handle then
		return
	end
	handle.SetInventory(payload)
end

function WeaponInventoryClient.Start(
	hudHandle: WeaponInventoryModule.WeaponInventoryHandle,
	notifyHandle: Notify.NotifyHandle?
): ()
	if started then
		return
	end
	started = true
	hud = hudHandle
	notify = notifyHandle

	local remote = NetworkBridge.GetRemoteEvent(WeaponConstants.Network.RemoteNames.InventoryChanged)
	remote.OnClientEvent:Connect(onInventoryChanged)

	logger:debug("WeaponInventoryClient started")
end

return WeaponInventoryClient
