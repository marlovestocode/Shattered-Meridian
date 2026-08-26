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

local WeaponInventoryModule = require(script.Parent.Parent.UI.Screens.WeaponInventory)

local logger = Logger.scope("WeaponInventoryClient")

local WeaponInventoryClient = {}

local started = false

-- Handed in by Main.client.lua from uiHandles.WeaponInventory, the same "screen exposes state, client
-- module drives it" split every other HUD-driving module here uses.
local hud: WeaponInventoryModule.WeaponInventoryHandle? = nil

local function onInventoryChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: WeaponConstants.InventoryPayload
	if typeof(payload.Owned) ~= "table" then
		return
	end

	local handle = hud
	if not handle then
		return
	end
	handle.SetInventory(payload)
end

function WeaponInventoryClient.Start(hudHandle: WeaponInventoryModule.WeaponInventoryHandle): ()
	if started then
		return
	end
	started = true
	hud = hudHandle

	local remote = NetworkBridge.GetRemoteEvent(WeaponConstants.Network.RemoteNames.InventoryChanged)
	remote.OnClientEvent:Connect(onInventoryChanged)

	logger:debug("WeaponInventoryClient started")
end

return WeaponInventoryClient
