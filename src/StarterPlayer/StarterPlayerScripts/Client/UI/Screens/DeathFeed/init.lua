--!strict
--[[
	DeathFeed.lua

	Owns: the mount point for the death/respawn overlay and kill feed named in
	ui-ux-philosophy.md's "Death/respawn and kill feed" surface.

	THE KILL FEED HAS NO PRODUCER. This header used to say it was "driven directly by
	Client/Combat/CombatClient.lua's Combat_KillFeed handler via imperative Instance.new calls into
	this Frame". That module was deleted in the combat rewrite (cc05003) and took the handler with it:
	`grep -rn Combat_KillFeed src/` finds this paragraph and nothing else, and KillFeedList has been an
	empty transparent Frame ever since. Written down rather than quietly corrected because the old
	sentence read exactly like a description of working integration, which is how it survived a
	rewrite that removed the thing it described.

	Nothing here fabricates a replacement -- a feed needs a server System that publishes kill
	attribution, and that is not this file's to invent. What this file does provide is the seam:
	KillFeedVisible on the returned handle, false today, which a producer must flip when it starts
	parenting rows in.

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
local Layers = require(script.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Shell.Surface)
local DeathOverlay = require(script.Parent.Parent.Components.DeathOverlay)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type DeathFeedHandle = {
	-- Shows the death overlay for the LOCAL player's own death. killerName is nil for an
	-- environmental/non-attributed death -- see DeathOverlay.DeathOverlayDisplay's own header.
	ShowDeath: (killerName: string?) -> (),
	ClearDeath: () -> (),
	-- Whether the kill feed tile is in its region's stack at all. False, and nothing sets it true --
	-- the feed has had no producer since the combat rewrite. See the note at its construction below
	-- for what a future producer has to do besides parenting rows in.
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
	-- KillFeedVisible EXISTS BECAUSE NOTHING FILLS THIS. The header above says the feed is driven by
	-- Client/Combat/CombatClient.lua's Combat_KillFeed handler; that module was deleted in the combat
	-- rewrite (cc05003) and took the handler with it, so there is no producer anywhere in the tree and
	-- has not been for some time. Left false, the tile is skipped by the region's UIListLayout
	-- entirely -- no height, and no share of the gap between tiles either.
	--
	-- Whoever writes the producer has to flip this as well as parenting rows in. A Visible tile with
	-- no children is not free once it is in a stack: it still takes the region's tile gap, which would
	-- shift the fuel gauge down by 8px for no visible reason. That is exactly the kind of thing a
	-- comment does not prevent, which is why it is a handle field rather than a note.
	local killFeedVisible: Fusion.Value<boolean> = scope:Value(false)

	local killFeedTile = scope:New "Frame" {
		Name = "KillFeedList",
		Size = UDim2.fromOffset(320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = killFeedVisible,

		[Children] = scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	} :: Frame

	return {
		ShowDeath = showDeath,
		ClearDeath = clearDeath,
		KillFeedVisible = killFeedVisible,
	}, killFeedTile
end

return DeathFeed
