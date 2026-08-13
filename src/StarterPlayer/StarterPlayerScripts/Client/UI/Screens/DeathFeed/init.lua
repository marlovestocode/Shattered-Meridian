--!strict
--[[
	DeathFeed.lua

	Owns: the mount point for the death/respawn overlay and kill feed named in
	ui-ux-philosophy.md's "Death/respawn and kill feed" surface.

	The kill feed (KillFeedList below) is driven directly by Client/Combat/CombatClient.lua's
	Combat_KillFeed handler via imperative Instance.new calls into this Frame -- unchanged by this
	pass (that handler predates this module's Fusion content and resolves this ScreenGui/Frame by
	NAME from PlayerGui rather than through Mount's return value, so it isn't affected by anything
	below).

	The death overlay (DeathOverlay component, Components/DeathOverlay.lua) is the real content this
	Mount() call now exists to drive: Client/Combat/CombatClient.lua's Kind == "Death" feedback
	branch calls ShowDeath() the moment the LOCAL player's own death is confirmed (gated there to the
	payload's TargetUserId -- the killer's own client receives the identical payload and must never
	trigger this), and ClearDeath() the moment that player's own CharacterAdded fires (respawn) --
	the same "translate an already-computed server fact into a call against this file's returned
	handle" boundary CombatFeedback.lua's own header documents for its LockOn/PostureBreak/Disarmed
	siblings.

	ShowDeath's own countdown display (SecondsRemaining, fed to DeathOverlay) is a task.delay chain
	here, not a per-frame RunService clock -- ticks in whole seconds from
	math.ceil(Constants.Respawn.DelaySeconds) down to 0, the same generation-guarded "only the most
	recent trigger's timer may act" idiom CombatClient.lua's postureBreakGeneration/
	disarmedGeneration and Server/Systems/RespawnSystem.lua's respawnGeneration already use for "a
	delayed action must not act on a superseded world." deathGeneration guards it: a rapid re-death
	(killed again before ClearDeath's own state from the previous life has settled) invalidates the
	earlier chain rather than letting two countdowns race each other. This is an ESTIMATE of the
	server's own respawn timer, not a guarantee -- RespawnSystem.lua schedules its own
	task.delay(Config.DelaySeconds, ...) off the same confirmDeath call this client's Death feedback
	rides on, so the two start within the same network round-trip of each other, but ClearDeath is
	what actually ends the overlay, off the real CharacterAdded -- a countdown that undershoots or
	overshoots by a beat never desyncs the overlay's actual lifetime from reality, only the number
	displayed while it's up.

	Design note: these moments are high-visibility but must never read as a punishment screen
	(gameplay-philosophy.md's anti-pattern against punishing engagement) -- see DeathOverlay.lua's
	own header for how that's carried into the actual copy/visual treatment.

	Mount() now returns a handle (ShowDeath/ClearDeath), not the bare ScreenGui -- the same shape
	CombatFeedback.lua's Mount() already uses for CombatClient-driven ephemeral combat UI, adopted
	here for the identical reason: real content driven by a remote-translating integration module
	needs somewhere to receive that state. Nothing outside this module ever looked up the OLD return
	value (see the kill-feed note above), so this is not a breaking change to any existing caller --
	only UI/init.lua's own Mount() capture and Client/Main.client.lua's CombatClient.Start() call
	needed to change alongside it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Tokens)
local DeathOverlay = require(script.Parent.Parent.Components.DeathOverlay)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type DeathFeedHandle = {
	-- Shows the death overlay for the LOCAL player's own death. killerName is nil for an
	-- environmental/non-attributed death -- see DeathOverlay.DeathOverlayDisplay's own header.
	ShowDeath: (killerName: string?) -> (),
	ClearDeath: () -> (),
}

local DeathFeed = {}

function DeathFeed.Mount(scope: Scope, playerGui: PlayerGui): DeathFeedHandle
	local deathDisplay: Fusion.Value<DeathOverlay.DeathOverlayDisplay?> =
		scope:Value(nil :: DeathOverlay.DeathOverlayDisplay?)
	local secondsRemaining: Fusion.Value<number> = scope:Value(0)

	-- See file header. Guards the tick chain below against a stale chain from an earlier death
	-- outliving a fresher one.
	local deathGeneration = 0

	local function tick(generation: number, remaining: number): ()
		if deathGeneration ~= generation then
			return
		end
		secondsRemaining:set(remaining)
		if remaining <= 0 then
			return
		end
		task.delay(1, tick, generation, remaining - 1)
	end

	local function showDeath(killerName: string?): ()
		deathGeneration += 1
		local generation = deathGeneration
		deathDisplay:set({ KillerName = killerName })
		tick(generation, math.ceil(Constants.Respawn.DelaySeconds))
	end

	local function clearDeath(): ()
		deathGeneration += 1
		deathDisplay:set(nil)
	end

	scope:New "ScreenGui" {
		Name = "DeathFeed",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = {
			DeathOverlay(scope, { Display = deathDisplay, SecondsRemaining = secondsRemaining }),
			scope:New "Frame" {
				Name = "KillFeedList",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -Tokens.Space.L, 0, Tokens.Space.L),
				Size = UDim2.fromOffset(320, 200),
				BackgroundTransparency = 1,

				[Children] = scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					Padding = UDim.new(0, Tokens.Space.XS),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
			},
		},
	}

	return {
		ShowDeath = showDeath,
		ClearDeath = clearDeath,
	}
end

return DeathFeed
