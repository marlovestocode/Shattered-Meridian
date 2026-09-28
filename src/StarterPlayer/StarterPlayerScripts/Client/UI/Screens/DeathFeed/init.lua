--!strict
--[[
	DeathFeed.lua

	Owns: the mount point for the death/respawn overlay and kill feed named in
	ui-ux-philosophy.md's "Death/respawn and kill feed" surface.

	THE PRODUCER IS Client/Combat/DeathNoticeClient.lua (since 2026-09-28), reading the Death_Notice
	broadcast Server/Systems/PlayerDeathSystem.lua sends once per confirmed death. For the LOCAL
	player's own death it calls ShowDeath(killerName) -- the victim's client only, gated there on the
	notice's VictimUserId -- and ClearDeath() the moment that player's next character arrives. For
	every ATTRIBUTED death it calls PushKill, which adds a row to the kill feed below. Unattributed
	deaths never reach the feed: a fall is the victim's news, not the server's. This file only renders;
	every one of those decisions is the producer's, the same "translate an already-computed server fact
	into a call against this file's returned handle" boundary CombatFeedback.lua documents.

	(Before that, the kill feed had no producer at all: the deleted CombatClient.lua's Combat_KillFeed
	handler went with the combat rewrite, and KillFeedList sat empty for months. The death overlay had
	lost its caller the same way.)

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
local Layers = require(script.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Shell.Surface)
local DeathOverlay = require(script.Parent.Parent.Components.DeathOverlay)
local KillFeedRow = require(script.Parent.Parent.Components.KillFeedRow)
local DeathConstants = require(ReplicatedStorage.Shared.Death.DeathConstants)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type DeathFeedHandle = {
	-- Shows the death overlay for the LOCAL player's own death. killerName is nil for an
	-- environmental/non-attributed death -- see DeathOverlay.DeathOverlayDisplay's own header.
	ShowDeath: (killerName: string?) -> (),
	ClearDeath: () -> (),
	-- Whether the local player is down right now, off the same Value that drives the overlay above --
	-- so the two can never disagree. Read by Shell/Chrome.lua, which turns it into the Dead UI mode;
	-- exposed rather than duplicated because "is this player dead" is this screen's fact to publish
	-- and Chrome's rule is that it derives modes rather than being told them.
	Dead: Fusion.Computed<boolean>,
	-- Adds one attributed kill to the feed. KillerName/VictimName are display strings; Involvement is
	-- the local player's part in it, decided by the producer.
	PushKill: (killerName: string, victimName: string, involvement: KillFeedRow.Involvement) -> (),
	-- Whether the kill feed tile is in its region's stack at all -- true exactly while it holds a row.
	-- Owned by PushKill and each row's expiry; exposed for the Storybook and specs, not for producers.
	KillFeedVisible: Fusion.Value<boolean>,
}

local DeathFeed = {}

-- THE ONLY ONE OF THE SIX REGION-HOSTED SCREENS THAT STILL TAKES A playerGui, because it is the only
-- one contributing something that is not a tile. It returns two things: the kill feed TILE, which
-- Shell/Regions.lua places in TopRight, and a handle -- and it keeps a ScreenGui of its own for the
-- death overlay, which is a centred full-screen surface rather than a corner tile and has no region
-- to belong to. That surface moves onto Shell/Surface.lua at Layers.Overlay in Phase 2; splitting it
-- out here would have meant inventing half of Surface early.
function DeathFeed.Mount(scope: Scope, playerGui: PlayerGui, scale: Fusion.UsedAs<number>): (DeathFeedHandle, Frame)
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

	-- THE ONE SURFACE THIS SCREEN STILL OWNS, and Phase 2's is the band it was always missing. Phase 1
	-- split this screen in two: the kill feed became a TopRight region tile with no ScreenGui at all,
	-- and this centred death card kept a surface of its own because it is not a tile -- it places
	-- itself, deliberately, in the middle of the screen. Layers.Overlay is where "the screen is
	-- telling you something happened" sits: over the dock, under a panel you opened.
	--
	-- Scaled, per the rule in Shell/Surface.lua's header -- the dock stays up through the death
	-- overlay (there is no yielding until Phase 3), so this card is chrome beside the dock and the two
	-- have to agree about how big the screen is.
	Surface.New(scope, {
		Name = "DeathFeed",
		Layer = Layers.Overlay,
		Parent = playerGui,
		Scaled = true,
		Scale = scale,

		Children = DeathOverlay(scope, { Display = deathDisplay, SecondsRemaining = secondsRemaining }),
	})

	-- SIZED FROM ZERO, NOT FROM 320x200 AS IT USED TO BE. This tile now shares the TopRight stack
	-- with the blimp fuel gauge, and a fixed 200px height would push the gauge 200px down the screen
	-- to make room for a feed that is always empty -- turning a bug nobody can see into one everybody
	-- can, in the name of fixing it. AutomaticSize.Y from a zero height means it costs exactly the
	-- entries it holds.
	--
	-- KillFeedVisible TRACKS WHETHER THERE IS A ROW, and setRows above is the only writer. A Visible
	-- tile with no children is not free once it is in a stack: it still takes the region's tile gap,
	-- which would shift the fuel gauge down by 8px for no visible reason. So the tile leaves the stack
	-- the moment its last row expires, rather than trusting a producer to remember to hide it.
	-- See the handle's Dead field. A Computed rather than a second Value for the usual reason: a
	-- second Value is a second edge somebody has to remember to set, and showDeath/clearDeath above
	-- already have exactly one.
	local dead = scope:Computed(function(use): boolean
		return use(deathDisplay) ~= nil
	end)

	local killFeedVisible: Fusion.Value<boolean> = scope:Value(false)

	-- Keyed by a per-row serial, so ForPairs keeps a row's Instance for its whole life and an expiry
	-- removes exactly the row it was scheduled for -- the same keyed-map shape CombatFeedback's damage
	-- numbers use, for the same reason (ForValues dedupes by value, not by identity).
	local rows: Fusion.Value<{ [number]: KillFeedRow.KillFeedEntry }> = scope:Value({})
	local rowSerial = 0

	local function setRows(nextRows: { [number]: KillFeedRow.KillFeedEntry }): ()
		rows:set(nextRows)
		-- Visible only while there is something in it -- see the tile's own note below on why an empty
		-- Visible tile is not free in a region stack.
		killFeedVisible:set(next(nextRows) ~= nil)
	end

	local function pushKill(killerName: string, victimName: string, involvement: KillFeedRow.Involvement): ()
		rowSerial += 1
		local serial = rowSerial
		local updated = table.clone(Fusion.peek(rows))
		updated[serial] = {
			KillerName = killerName,
			VictimName = victimName,
			Involvement = involvement,
			Order = serial,
		}
		-- Over the cap, the oldest goes: serials are increasing, so the smallest key is the oldest row.
		local count = 0
		local oldest: number? = nil
		for key in updated do
			count += 1
			if oldest == nil or key < oldest then
				oldest = key
			end
		end
		if count > DeathConstants.KillFeed.MaxRows and oldest ~= nil then
			updated[oldest] = nil
		end
		setRows(updated)

		task.delay(DeathConstants.KillFeed.RowSeconds, function()
			local latest = Fusion.peek(rows)
			if latest[serial] == nil then
				return
			end
			local remaining = table.clone(latest)
			remaining[serial] = nil
			setRows(remaining)
		end)
	end

	local killFeedTile = scope:New "Frame" {
		Name = "KillFeedList",
		Size = UDim2.fromOffset(320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = killFeedVisible,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:ForPairs(rows, function(_use, innerScope, serial, entry)
				return serial, KillFeedRow(innerScope, entry)
			end),
		},
	} :: Frame

	return {
		Dead = dead,
		ShowDeath = showDeath,
		ClearDeath = clearDeath,
		PushKill = pushKill,
		KillFeedVisible = killFeedVisible,
	},
		killFeedTile
end

return DeathFeed
