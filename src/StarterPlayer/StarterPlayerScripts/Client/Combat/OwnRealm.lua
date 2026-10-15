--!strict
--[[
	OwnRealm.lua

	Owns: what the LOCAL player knows about their own standing realm, as a small plain-data mirror -- which move cast
	it, when it can be ended early, and when it ends. The one thing the cancel timer (UI/Screens/RealmCancel) reads.

	WHY A MODULE OF ITS OWN. The realm's views already arrive on the client, in Client/FX/DomainFX.lua, which keeps
	them as its own presentation state: shells, interiors, cue schedules. The HUD needs three of those facts and
	nothing else, and an FX module is the wrong thing for a screen to reach into. So DomainFX WRITES here, as it
	handles each server message, and the HUD READS -- the same one-way "outside module writes, screen reads" shape
	HotbarBindings and AttackInputClient.OnSlotCooldown already give the HUD.

	TIMES ARE ON THE SHARED SERVER CLOCK (DomainRules.ServerNow), exactly as the server stated them, never converted
	to the local clock here: a reader converts when it draws, so a clock that drifts is never frozen into the state.

	ONE REALM. A player owns at most one live realm (DomainSystem.Open refuses a second), so this holds one or none.
	A realm that is folding or finished is not held: by then there is nothing left to cancel.

	Does not own: whether a realm may be cancelled (the server's DomainSystem.TryCancel decides, this only mirrors
	the moment it will allow), or how any of it is drawn.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("OwnRealm")

export type State = {
	Id: string,
	-- The move whose press ends this realm (and whose hotbar slot the timer names the key of).
	MoveId: string,
	-- Server-clock time the realm opened, and from which it may be ended (DomainView.CancelableAt).
	OpenedAt: number,
	CancelableAt: number,
	-- Server-clock time the realm's law ends and its fold begins. 0 until the server has stated one.
	LawEndsAt: number,
}

local OwnRealm = {}

local current: State? = nil
local listeners: CallbackList.CallbackList<State?> = CallbackList.New(logger, "OwnRealm.OnChanged")

local function publish(): ()
	listeners:Fire(current)
end

-- A realm of the local player's opened (or was found already standing). `view` is the server's DomainView.
-- A view with CancelableAt 0 is a realm no press can end, so there is nothing for a timer to count to and it is
-- not held.
function OwnRealm.Open(view: DomainTypes.DomainView): ()
	-- Nothing to wait for: no press can end it (CancelableAt 0), or it is already folding (a snapshot of a realm
	-- caught mid-fold).
	if view.CancelableAt <= 0 or view.Phase == "Ending" or view.Phase == "Finished" then
		OwnRealm.Close(view.Id)
		return
	end
	current = {
		Id = view.Id,
		MoveId = view.MoveId,
		-- The realm's first phase starts when it opens; a view joined mid-phase says a later one, which only
		-- makes the bar's start a little late for a realm the player joined into.
		OpenedAt = view.PhaseStartedAt,
		CancelableAt = view.CancelableAt,
		LawEndsAt = if view.Phase == "Active" then view.PhaseEndsAt else 0,
	}
	publish()
end

-- The realm moved to a new phase. Active states when the law ends; Ending or Finished means it can no longer be
-- cancelled, so it is dropped.
function OwnRealm.Phase(id: string, phase: string, phaseEndsAt: number): ()
	local state = current
	if state == nil or state.Id ~= id then
		return
	end
	if phase == "Ending" or phase == "Finished" then
		OwnRealm.Close(id)
		return
	end
	if phase == "Active" then
		state.LawEndsAt = phaseEndsAt
		publish()
	end
end

-- The realm `id` is gone (or was never the local player's to hold).
function OwnRealm.Close(id: string): ()
	local state = current
	if state ~= nil and state.Id == id then
		current = nil
		publish()
	end
end

function OwnRealm.Get(): State?
	return current
end

-- Fires with the new state (nil when the realm ended) on every change. Returns the disconnect.
function OwnRealm.OnChanged(callback: (State?) -> ()): () -> ()
	return listeners:Connect(callback)
end

-- Spec-only: forget everything, including subscribers.
function OwnRealm.Reset(): ()
	current = nil
	listeners:Clear()
end

return OwnRealm
