--!strict
--[[
	AttackTypes.lua

	Owns: the shapes the Attack layer is written in -- what a player is asking to throw
	(AttackRequest), and what the server tells them it actually started (AttackStartedPayload).

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was
	    DamageSystem     how much it hurts, what it does to you
	    AttackLayer      what you are trying to throw, and whether you may   <- this system

	Deliberately NOT a section of Shared/Types.lua, for the same reason DefenseTypes.lua,
	HitboxTypes.lua and DamageTypes.lua are not: this system is a module, and a system whose types
	live somewhere else is one that cannot be removed without unpicking that somewhere else.

	THE REQUEST CARRIES NO GEOMETRY, ON PURPOSE. There is no target, no position, no direction and no
	client timestamp anywhere in AttackRequest -- only which BUTTON was pressed. The server derives
	every geometric fact from the character's own live rig (HitboxEngine's "the pose is never baked"
	rule) and every timing fact from its own arrival clock. A client that lies about this payload can
	only ever lie about which of its own buttons it pressed, which is not a lie worth telling.

	MoveId IS THE ONE EXCEPTION, and it is gated rather than trusted -- see AttackRequest.MoveId
	below for why the hotbar has to work this way and what stops it being a "throw anything" hole.

	Does not own: the tunables (AttackConstants.lua), which move a press resolves to (SwingSequencer),
	whether a combatant may throw at all (AttackRequestSystem, gating through DefenseSystem/
	DamageSystem), or what a landed hit costs (DamageResolver).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)

local AttackTypes = {}

-- Which button was pressed, not which move it means. The mapping from one to the other is
-- SwingSequencer's job and is re-decided on every single press, because "what throws next" depends
-- on server state (how far into the string you are, how deep your landed combo is) that a client
-- cannot be the authority on.
export type AttackKind =
	-- The light-attack string. Cycles stages and can tip into a Finisher -- see SwingSequencer.
	"Basic"
	-- The heavy string. Its own independent stage counter; switching between the two resets whichever
	-- you switched away from, so a player cannot alternate presses to skip to the end of both.
	| "Heavy"
	-- An authored move fired straight from a hotbar slot, bypassing both strings.
	| "Hotbar"

export type AttackRequest = {
	Kind: AttackKind,
	-- 1..AttackConstants.Hotbar.SlotCount, and only meaningful for Kind == "Hotbar".
	Slot: number?,
	-- Only meaningful for Kind == "Hotbar", and NOT TRUSTED, for anyone, admin included -- see
	-- Server/Combat/Attack/AttackRequestSystem.lua's resolveRequest.
	--
	-- Slot is checked against ArtSystem.GetEquipped(player) and that is the WHOLE resolution: MoveId
	-- is ignored entirely and the equipped ArtId is gated on ArtSystem.CanUse instead. A hotbar slot
	-- can only ever hold a real, persisted Art -- ArtSystem.Equip for the normal ArtsTab flow,
	-- ArtSystem.DevGrantAndEquip for an admin's Move Editor "bind to slot" test-fire (see that
	-- function's own header) -- so there is no second kind of MoveId an admin account could have this
	-- field trusted for. An admin equipping an Art normally must feel the same Qi cost/mastery/tier/
	-- Deviation gating anyone else does, not a free pass just because their account also carries
	-- dev-tool trust. A slot with nothing equipped simply refuses -- MoveId was never read at all.
	MoveId: string?,
}

-- What the server tells the ATTACKER the instant it accepts a throw. Nobody else is told: this is a
-- presentation sync for the person who pressed the button, not a broadcast.
--
-- Mirrors the deleted Types.AttackStartedPayload almost field for field. That shape was already
-- right for its one job -- letting the client's animation/FX layer sync to what the server actually
-- scheduled -- and nothing about the rebuilt engine changes what that job needs.
export type AttackStartedPayload = {
	MoveId: string,
	-- Echoed back so a client that fired several presses in flight can tell which one this answers.
	Kind: AttackKind,
	Slot: number?,
	WeaponId: Types.WeaponId,
	-- Which stage of the string this was. 0 means the Finisher, matching DefaultMoveRegistry's own
	-- stageIndex sentinel rather than inventing a second convention.
	StageIndex: number,
	-- The attacker's LANDED-hit combo stage at throw time (ComboEscalation), which is a different
	-- number from StageIndex above and always has been -- see SwingSequencer's header on why those
	-- two counters were never one.
	ComboStage: number,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	-- How long until this same move may be thrown again, from now. The client uses it to drive the
	-- hotbar's own cooldown readout; the server enforces it regardless of whether the client does.
	CooldownSeconds: number,
	-- The authored clip for this move, or "" when the move has none (every Default move today -- see
	-- DefaultMoveRegistry's header). Sent rather than looked up client-side because the Move Editor
	-- can change it at runtime, and a client cache would serve the previous clip until rejoin.
	AnimationId: string,
	-- The speed to play AnimationId at. The server built Windup/Active/Recovery against the clip's real
	-- length at THIS speed (AttackCatalog.Get), so playing it at any other speed puts the hit frame
	-- somewhere the hitbox is not. The weapon's own WeaponSpeed; 1 for anything without one.
	PlaybackSpeed: number,
}

-- Server -> owner, on every change to which weapon their strings come from. Its own event rather
-- than a field on AttackStartedPayload above: a swap is exactly the case where NO attack started.
export type WeaponChangedPayload = {
	WeaponId: Types.WeaponId,
}

return AttackTypes
