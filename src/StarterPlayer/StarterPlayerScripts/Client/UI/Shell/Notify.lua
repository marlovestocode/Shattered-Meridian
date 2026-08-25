--!strict
--[[
	Shell/Notify.lua

	Owns: the client's one notification channel -- the queue behind it, which notification is current,
	how long each stays up, what happens when two arrive in the same second, and what each kind looks
	like.

	Does NOT own: any pixels (Screens/Notifications draws the tile -- see the split below), or
	anything that decides a notification should exist. Every producer lives at its own owner and
	calls Push; this file has no opinion about what is worth telling a player.

	Phase 6 of docs/architecture/2026-08-25-hud-shell-plan.md, closing 2.9. Before it, the client had
	one bespoke centre-top banner (Screens/Announcement, admin broadcasts) and one bespoke top-right
	list (Screens/DeathFeed's kill feed, which has had no producer since the combat rewrite). The
	philosophy doc's Notification Design section -- item acquired, rank change, progression milestone
	-- had no surface at all, and a rank-up could not say so in words anywhere on screen.

	================================================================================================
	THE TILE IS NOT IN THIS FILE, AND THE PLAN SAID IT WOULD BE
	================================================================================================

	Plan 3.5 specs "one prioritised queue feeding one TopCentre region tile" as one module. It is two,
	because Shell/ MAY NOT REQUIRE Components/ -- Shell/Regions.lua's COMBAT_BANNER_BAND_BOTTOM note
	states that rule and pays for it by duplicating two numbers rather than importing them, and the
	direction is load-bearing: Components/ModalScreen.lua requires Shell/Surface and Shell/Layers, so
	an arrow back the other way is a cycle waiting for its second edge.

	Splitting it is also the same split Chrome/Regions already made and for the same gain: everything
	here is a table and a task.delay, so Tests/UI/Notify.spec.lua drives the whole queue -- priority,
	coalescing, the depth cap -- with no render pass at all. What is left in Screens/Notifications is
	a tile that reads one Value.

	KIND STYLING STAYS HERE rather than going with the tile, because it is a statement about the
	channel rather than about the drawing: which kinds exist, which outranks which, how long each is
	worth reading, and what each is called. Tokens is not Components, and Shell/Regions.lua already
	requires it.

	================================================================================================
	ONE CHANNEL PLUS ONE PRODUCER, AND THE SECOND HALF IS THE RESTRAINT
	================================================================================================

	The kind enum has four entries because the philosophy doc names four kinds of notification, and
	exactly ONE of them is wired: ClientState.TierPromotion, which is real, server-driven and already
	carries both the From and the To tier (that is why its type is a table and not a boolean).

	Acquisition, World and Warning are declared and unused. That is deliberate and it is this repo's
	standing rule: a Notification Design item stays unbuilt until its owning System publishes real
	data, and inventing content ahead of the server is how a UI ends up with a pickup toast that
	fires off a client guess. Each of the three costs one line in KIND_STYLE and nothing else, so the
	day an inventory System publishes an acquisition, the channel is already there.

	TierBadge's promotion flare stays exactly as it is. The flare is the FELT cue -- a colour surge on
	the badge, in the corner of the eye, during a fight -- and this is the READABLE one. They are not
	redundant; one tells you something happened and the other tells you what.

	================================================================================================
	ONE AT A TIME, AND A QUEUE RATHER THAN A STACK OF TILES
	================================================================================================

	The alternative -- a column of simultaneous toasts -- was rejected on the doc's HUD rule
	("minimal, informative, out of the player's way"). Three notifications at once in the top centre
	of the screen, over live combat, is the opposite of out of the way. So there is one tile, one
	visible notification, and everything else waits its turn.

	PRIORITY IS BY KIND, FIFO WITHIN A KIND. A Warning that arrives behind four World notices should
	not wait twenty seconds; a second Acquisition should not jump ahead of the first. KIND_PRIORITY
	below is the whole of the ordering.

	IT DOES NOT PREEMPT. A higher-priority notification goes to the FRONT of the queue, not onto the
	screen -- whatever is currently showing finishes. Cutting a notification off mid-read to show a
	different one means the player reliably reads neither, and the longest anything can delay a
	Warning is one Duration.

	COALESCING IS BY CONTENT, NOT BY KIND. Two pushes with the same Kind, Title and Detail are one
	notification: the duplicate is dropped, and if the match is the one currently showing, its timer
	restarts so the player gets a full read from the most recent occurrence. Kind alone would be
	wrong -- two different rank-ups are two different facts and must both be readable.

	THE QUEUE IS CAPPED, WITH A STATED DROP POLICY. At MAX_QUEUE waiting entries the LOWEST-priority,
	OLDEST waiting entry is dropped to make room -- and if the arriving notification is no better than
	that entry, the arriving one is what does not get in. Dropping the newest unconditionally would
	let a burst of World notices lock a Warning out; dropping the oldest unconditionally would do the
	reverse. An unbounded queue is worse than both: a producer stuck in a loop would build a backlog
	the player then has to sit through for minutes.

	================================================================================================
	NO RunService CONNECTION (plan 11 rule 1)
	================================================================================================

	Dismissal is a task.delay with a generation guard, not a per-frame deadline check. A notification
	channel is idle almost all of the time, and a Heartbeat that exists to notice one expiry a minute
	is the exact idle cost this layer is supposed to have none of. The generation counter is what
	makes a stale delay a no-op -- the same shape Screens/BugReport's status clear already uses -- and
	it is why nothing here needs a timer to cancel.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

-- The four kinds docs/ui-ux-philosophy.md's Notification Design section names. Only Progression has
-- a producer today -- see this file's header on why the other three are declared anyway.
export type Kind = "Progression" | "Acquisition" | "World" | "Warning"

export type Notification = {
	Kind: Kind,
	-- The fact, in the fewest words that carry it. One line; it does not wrap.
	Title: string,
	-- The reading of the fact. Optional, one line, and the place a number belongs.
	Detail: string?,
	-- Seconds on screen. Defaults per kind -- see KIND_STYLE.
	Duration: number?,
}

export type KindStyle = {
	Accent: Color3,
	-- The word above the title. Fixed per kind, so the player learns the shape rather than reading it.
	Eyebrow: string,
	Duration: number,
}

export type NotifyHandle = {
	-- Queue it. Returns nothing: whether a notification is shown now, shown later, coalesced into one
	-- already waiting, or dropped for depth is this module's decision and not the producer's problem.
	Push: (self: NotifyHandle, notification: Notification) -> (),
	-- What is on screen right now, or nil. Read by Screens/Notifications and by the specs; a producer
	-- has no business reading it.
	Current: Fusion.Value<Notification?>,
	-- How many are waiting behind the current one. Specs and the Storybook only.
	Depth: (self: NotifyHandle) -> number,
}

-- Higher wins a place nearer the front of the queue. Warning outranks everything because it is the
-- only kind that can be about something the player must act on; World is last because it is the only
-- kind that is about the server rather than about this player.
local KIND_PRIORITY: { [Kind]: number } = {
	Warning = 40,
	Progression = 30,
	Acquisition = 20,
	World = 10,
}

-- ACCENTS ARE THE EXISTING PALETTE, NOT FOUR NEW COLOURS. A notification is chrome, and chrome in
-- this UI is violet for the player's own progress, bronze for a thing acquired, and the Warning
-- token for a warning. World takes TextSecondary rather than an accent on purpose: a server-wide
-- notice is not about this player, and giving it an accent would put it in the same visual class as
-- their own rank-up.
local KIND_STYLE: { [Kind]: KindStyle } = {
	Progression = { Accent = Tokens.Color.AccentPrimary, Eyebrow = "ASCENSION", Duration = 5 },
	Acquisition = { Accent = Tokens.Color.AccentSecondary, Eyebrow = "ACQUIRED", Duration = 4 },
	World = { Accent = Tokens.Color.TextSecondary, Eyebrow = "THE MERIDIAN", Duration = 5 },
	Warning = { Accent = Tokens.Color.Warning, Eyebrow = "WARNING", Duration = 6 },
}

-- Waiting entries, not counting the one on screen. Eight is generous for a channel with one real
-- producer and is chosen to be obviously bounded rather than tuned -- see the drop policy in this
-- file's header for what happens at the cap.
local MAX_QUEUE = 8

local function sameNotification(a: Notification, b: Notification): boolean
	return a.Kind == b.Kind and a.Title == b.Title and a.Detail == b.Detail
end

local Notify = {}

-- The kinds, in priority order. For the Storybook, and for a producer choosing between them.
Notify.Kinds = table.freeze({ "Warning", "Progression", "Acquisition", "World" } :: { Kind })

-- What a kind looks like and how long it is worth reading. The one thing Screens/Notifications needs
-- from this file besides the current notification itself.
function Notify.Style(kind: Kind): KindStyle
	return KIND_STYLE[kind]
end

-- Builds the channel. Takes the scope as an argument and holds nothing globally, the same posture
-- every other module in Shell/ takes -- see Shell/Regions.lua's header for the hot-reload failure a
-- module-level cache causes.
function Notify.New(scope: Scope): NotifyHandle
	local current: Fusion.Value<Notification?> = scope:Value(nil :: Notification?)
	local queue: { Notification } = {}

	-- Bumped on every show, so a task.delay from a notification that has already been replaced finds
	-- a generation it does not match and does nothing. This is the whole of the timer management;
	-- there is nothing to cancel.
	local generation = 0

	local show: (notification: Notification) -> ()

	local function advance(): ()
		local nextUp = table.remove(queue, 1)
		if nextUp == nil then
			-- Bumped here too, so a stale delay cannot fire an advance into an empty channel and race
			-- a Push that arrives in the same frame.
			generation += 1
			current:set(nil)
			return
		end
		show(nextUp)
	end

	function show(notification: Notification): ()
		generation += 1
		local mine = generation
		current:set(notification)

		task.delay(notification.Duration or KIND_STYLE[notification.Kind].Duration, function()
			if generation ~= mine then
				return
			end
			advance()
		end)
	end

	-- The cap, with the policy stated in this file's header applied literally: find the lowest
	-- priority among the waiting entries and drop the oldest entry at that priority. Returns whether
	-- there is now room for `incoming`.
	local function makeRoom(incoming: Notification): boolean
		if #queue < MAX_QUEUE then
			return true
		end

		local worstIndex = 1
		local worstPriority = KIND_PRIORITY[queue[1].Kind]
		for index = 2, #queue do
			local priority = KIND_PRIORITY[queue[index].Kind]
			-- Strictly less, so a tie leaves the EARLIER entry as the victim and FIFO holds within a
			-- priority on the way out as well as on the way in.
			if priority < worstPriority then
				worstPriority = priority
				worstIndex = index
			end
		end

		-- The arriving notification is no better than the worst thing already waiting, so it is the
		-- one that does not get in. Evicting a queued entry for a peer would be churn with no gain.
		if KIND_PRIORITY[incoming.Kind] <= worstPriority then
			return false
		end

		table.remove(queue, worstIndex)
		return true
	end

	local handle: NotifyHandle
	handle = {
		Current = current,

		Push = function(_self, notification: Notification): ()
			local showing = peek(current)

			-- Coalesce against what is on screen: restart its read rather than queueing a second copy
			-- of something the player is already looking at.
			if showing ~= nil and sameNotification(showing, notification) then
				show(notification)
				return
			end
			for _, waiting in queue do
				if sameNotification(waiting, notification) then
					return
				end
			end

			if showing == nil then
				show(notification)
				return
			end

			if not makeRoom(notification) then
				return
			end

			-- Insert by priority, after every entry that is at least as important. Equal priority
			-- lands behind, which is what makes it FIFO within a kind.
			local insertAt = #queue + 1
			for index, waiting in queue do
				if KIND_PRIORITY[notification.Kind] > KIND_PRIORITY[waiting.Kind] then
					insertAt = index
					break
				end
			end
			table.insert(queue, insertAt, notification)
		end,

		Depth = function(_self): number
			return #queue
		end,
	}

	return handle
end

return Notify
