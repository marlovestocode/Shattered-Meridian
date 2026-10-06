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

local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ProjectileMotion = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileMotion)
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
	-- This client's own count of attack presses this session, the same scheme as the guard's press ids
	-- (DefenseSystem's verdict). Echoed on Attack_Started when the press throws, or answered with a "Refused"
	-- Attack_Cancelled when it will not, so a mispredicted swing is cut on the verdict rather than a timeout.
	-- An id at or below the last one seen from this player is a duplicate and dropped. Optional: a bot has none.
	PressId: number?,
	-- "Up" when the jump key (Space / gamepad A) was held at the press -- the air combo's modifier: Space + M1
	-- is the launcher branch, Space + Heavy in the air is the Spike (docs/design/air-combat-and-evade.md B2).
	-- Basic/Heavy only. The SERVER decides whether it means anything (SwingSequencer.Resolve, AirComboSystem),
	-- so a forged modifier can only ask for a launcher the string already earned.
	Modifier: "Up"?,
}

-- What the server tells the ATTACKER the instant it accepts a throw. Nobody else is told: this is a
-- presentation sync for the person who pressed the button, not a broadcast.
--
-- Mirrors the deleted Types.AttackStartedPayload almost field for field. That shape was already
-- right for its one job -- letting the client's animation/FX layer sync to what the server actually
-- scheduled -- and nothing about the rebuilt engine changes what that job needs.
-- A box, in the space of the part it is anchored on: Size, centred at Offset. What HitPrediction.Contains tests.
export type ContactBox = {
	Size: Vector3,
	Offset: CFrame,
}

-- The swing's volume for the attacker's own predicted hit cue (Client/Combat/HitPrediction), described the
-- way the engine builds it: a shape and its dimensions, composed as attachment part * Offset, with the
-- attachment resolved on the attacker's own rig through the shared HitboxAnchor chain. Any shape and any
-- anchor -- the client tests it with the engine's own HitboxGeometry.
--
-- Sent only when the client can reproduce the size exactly: a FLAT-scaled move (no combo, power or charge
-- growth -- every projected move today) that is not a projectile. Anything else sends nil and the hit waits
-- for the server, as every hit used to. SizeFromAttachmentPart is the engine's Box-only rule: the resolved
-- part's own Size, times SizeMultiplier, stands in for Width/Height/Length.
export type ContactVolume = {
	Shape: HitboxTypes.ShapeKind,
	Dimensions: HitboxTypes.Dimensions,
	Offset: CFrame,
	AttachmentPart: HitboxTypes.AttachmentPoint,
	SizeFromAttachmentPart: boolean?,
	SizeMultiplier: number?,
}

export type AttackStartedPayload = {
	MoveId: string,
	-- Echoed back so a client that fired several presses in flight can tell which one this answers.
	Kind: AttackKind,
	Slot: number?,
	-- nil for an art cast empty-handed (SwingSequencer.Resolution.WeaponId); readers already treat it as optional.
	WeaponId: Types.WeaponId?,
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
	-- Presentation only -- see ContactVolume. Never trusted for a hit: the server's engine decides every one.
	ContactVolume: ContactVolume?,
	-- The press this swing answers (AttackRequest.PressId), echoed so the client confirms the exact prediction.
	PressId: number?,
	-- True when this swing is the LAST M1 of its string, so a predicted hit off it plays the heavier
	-- string-ender beat (DamageTypes.CombatFeedback.StringEnd) without waiting on the server's verdict.
	StringEnd: boolean?,
}

-- Server -> owner, on every change to which weapon their strings come from: a swap, a draw or sheathe,
-- and every fresh life (AttackRequestSystem.notifyWeaponChanged). Its own event rather than a field on
-- AttackStartedPayload above: a swap is exactly the case where NO attack started.
export type WeaponChangedPayload = {
	-- nil for an empty hand (sheathed, or a life that has drawn nothing yet).
	WeaponId: Types.WeaponId?,
	-- One Attack_Started template per ground stage of WeaponId, Basic then Heavy, with no PressId and a
	-- ComboStage of 0 -- what the client predicts a swing from before that move has ever been confirmed.
	-- Presentation only, exactly like the confirmation it stands in for. Empty for an empty hand.
	Moves: { AttackStartedPayload }?,
}

-- Why the server cut a swing short -- see AttackConstants.Network.RemoteNames.Cancelled. "Feint" is the
-- attacker's own cancel (the string resets). "Parried" is sent after a parry, and only to say where the
-- string went BACK to (AttackRequestSystem.KeepChainThroughParry). "Traded" is the same for a trade -- two
-- swings that met (AttackRequestSystem.KeepChainThroughTrade) -- and its RecoverySeconds is when either side
-- may swing again. The swing itself was already cut through Combat_Feedback in both.
-- "Refused" is the press VERDICT (AttackRequest.PressId): the server will not throw that press -- refused on
-- arrival, or buffered and then expired, superseded by a newer press, or dropped with the swing it waited on.
-- The client cuts that press's prediction on it instead of waiting out a timeout. RefusedReason says why.
export type AttackCancelReason = "Feint" | "Parried" | "Traded" | "Refused"

-- Server -> the attacker alone, on Attack_Cancelled. Carries the MoveId so a client whose own
-- prediction has already moved on to a different swing can ignore a cancel that is not about it.
export type AttackCancelledPayload = {
	MoveId: string,
	Reason: AttackCancelReason,
	-- How long the attacker is locked out after the cancel -- the client's LocalCombatState holds its
	-- own swing prediction this long rather than guessing. For "Parried" this is the stagger.
	RecoverySeconds: number,
	-- "Parried" only: the string the server restored, so the client's prediction mirror continues it.
	-- StringKind nil means no string is live (the parried swing was a fresh string's first hit).
	StringKind: AttackKind?,
	StringStage: number?,
	-- On a "Refused" verdict: the press it answers, and why (a refusal reason, "Expired" or "Superseded").
	PressId: number?,
	RefusedReason: string?,
}

-- One change to one shot in flight, server -> every client on Attack_Projectile -- the wire form of
-- Server/Combat/HitboxEngine/ProjectileSimulator.ProjectileEvent (see its header for what each Kind means).
-- Presentation only: nothing a client does with it reaches the server, and every contact is still the
-- engine's answer alone.
export type ProjectileEventKind = "Launch" | "Update" | "End"
export type ProjectileWireEvent = {
	Kind: ProjectileEventKind,
	Id: number,
	GroupId: number,
	Position: Vector3,
	Velocity: Vector3,
	-- Seconds the event is older than SentAt (it happened earlier in the frame that sent it).
	Lead: number,
	Owner: Model?,
	MoveId: string?,
	Radius: number?,
	LifetimeSeconds: number?,
	Motion: ProjectileMotion.Motion?,
	Target: Model?,
	-- End: why the shot ended ("World", "Range", "Expired", "Hit", ...). Update: "Bounce" for a bounce off
	-- the world, nil otherwise (ProjectileSimulator's ProjectileEvent) -- presentation only.
	Reason: string?,
}

-- One engine frame's worth of shot changes. SentAt is Workspace:GetServerTimeNow() at the send, so a
-- client can fly each shot forward by exactly how old its event is by the time it arrives.
export type ProjectileBatchPayload = {
	SentAt: number,
	Events: { ProjectileWireEvent },
}

return AttackTypes
