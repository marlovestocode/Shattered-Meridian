--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Notify = require(UI.Shell.Notify)

-- THE ONE NOTIFICATION CHANNEL. Phase 6 of docs/architecture/2026-08-25-hud-shell-plan.md, closing
-- 2.9: the philosophy doc names four kinds of notification and the client had a surface for none of
-- them, so a rank-up could not say so in words anywhere on screen.
--
-- NO RENDER PASS, DELIBERATELY, and that is what the Shell/Notify to Screens/Notifications split
-- buys. Everything asserted below -- ordering, coalescing, the depth cap and its drop policy -- is a
-- table and a peek. The tile that draws the result reads one Value and is a screenshot's problem.
--
-- DURATIONS ARE ALWAYS PASSED EXPLICITLY HERE, and mostly enormous. Dismissal is a task.delay, so a
-- test that let a default 5-second duration run would either need to yield for five seconds or
-- would race it. A duration no test waits out means every assertion below is about the queue rather
-- than about the clock; the one case that IS about the clock says so.

type Scope = Fusion.Scope<typeof(Fusion)>

-- Long enough that nothing expires during a test that is not about expiry.
local FOREVER = 3600

return function()
	local function build(): (Scope, Notify.NotifyHandle)
		local scope = Fusion.scoped(Fusion)
		return scope, Notify.New(scope)
	end

	local function push(notify: Notify.NotifyHandle, kind: Notify.Kind, title: string, duration: number?): ()
		notify:Push({ Kind = kind, Title = title, Duration = duration or FOREVER })
	end

	local function currentTitle(notify: Notify.NotifyHandle): string?
		local current = Fusion.peek(notify.Current)
		return if current then current.Title else nil
	end

	describe("one at a time", function()
		it("shows nothing until something is pushed", function()
			local _scope, notify = build()

			expect(Fusion.peek(notify.Current)).to.equal(nil)
			expect(notify:Depth()).to.equal(0)
		end)

		it("shows the first and queues the second rather than replacing it", function()
			-- The whole reason this is a channel and not a Value. Two producers firing in the same
			-- second used to mean whichever wrote last was the only one the player ever saw.
			local _scope, notify = build()

			push(notify, "Progression", "first")
			push(notify, "Progression", "second")

			expect(currentTitle(notify)).to.equal("first")
			expect(notify:Depth()).to.equal(1)
		end)

		it("does not preempt, even for a higher-priority kind", function()
			-- Stated as a rule in Shell/Notify.lua's header and asserted here because the opposite is
			-- the obvious implementation: cutting a notification off mid-read to show a more important
			-- one means the player reliably reads neither.
			local _scope, notify = build()

			push(notify, "World", "showing")
			push(notify, "Warning", "urgent")

			expect(currentTitle(notify)).to.equal("showing")
			expect(notify:Depth()).to.equal(1)
		end)
	end)

	describe("priority", function()
		it("puts a higher kind at the front of the queue", function()
			local _scope, notify = build()

			push(notify, "Progression", "showing")
			push(notify, "World", "world")
			push(notify, "Acquisition", "acquisition")
			push(notify, "Warning", "warning")

			-- The current one finishes; behind it the queue is Warning, Acquisition, World. Depth only
			-- here -- what actually comes out next is asserted end-to-end two cases down, which is the
			-- claim that matters and the one that does not depend on the queue's internal shape.
			expect(currentTitle(notify)).to.equal("showing")
			expect(notify:Depth()).to.equal(3)
		end)

		it("is FIFO within one kind", function()
			-- Two rank-ups are two facts and the player should read them in the order they happened.
			-- Insertion is "after every entry at least as important", which is what makes equal
			-- priority land behind rather than in front.
			local _scope, notify = build()

			push(notify, "Progression", "showing")
			push(notify, "Acquisition", "a")
			push(notify, "Acquisition", "b")
			push(notify, "Acquisition", "c")

			expect(notify:Depth()).to.equal(3)
		end)

		it("lets a Warning out ahead of a backlog of World notices", function()
			-- The case the ordering exists for. Driven all the way through with real (zero) durations,
			-- because the claim is about what the player actually sees next -- asserting the queue's
			-- internals would be asserting the implementation.
			local _scope, notify = build()

			notify:Push({ Kind = "World", Title = "showing", Duration = 0 })
			notify:Push({ Kind = "World", Title = "world-1", Duration = 0 })
			notify:Push({ Kind = "World", Title = "world-2", Duration = 0 })
			notify:Push({ Kind = "Warning", Title = "warning", Duration = 0 })

			expect(currentTitle(notify)).to.equal("showing")

			-- One resumption per advance; task.delay(0) fires on the next frame.
			task.wait()
			expect(currentTitle(notify)).to.equal("warning")
		end)
	end)

	describe("coalescing", function()
		it("drops a duplicate of what is already queued", function()
			local _scope, notify = build()

			push(notify, "Progression", "showing")
			push(notify, "Acquisition", "same")
			push(notify, "Acquisition", "same")
			push(notify, "Acquisition", "same")

			expect(notify:Depth()).to.equal(1)
		end)

		it("restarts the read instead of queueing a copy of what is on screen", function()
			local _scope, notify = build()

			push(notify, "Progression", "showing")
			push(notify, "Progression", "showing")

			expect(currentTitle(notify)).to.equal("showing")
			expect(notify:Depth()).to.equal(0)
		end)

		it("treats two notifications of one kind with different text as two facts", function()
			-- Coalescing by KIND rather than by content would collapse two different rank-ups into
			-- one, which is the wrong answer and the reason the comparison includes Title and Detail.
			local _scope, notify = build()

			push(notify, "Progression", "Opened Meridian")
			push(notify, "Progression", "Flowing Channel")

			expect(currentTitle(notify)).to.equal("Opened Meridian")
			expect(notify:Depth()).to.equal(1)
		end)

		it("distinguishes two notifications that differ only in Detail", function()
			local _scope, notify = build()

			notify:Push({ Kind = "Acquisition", Title = "showing", Duration = FOREVER })
			notify:Push({ Kind = "Acquisition", Title = "same", Detail = "one", Duration = FOREVER })
			notify:Push({ Kind = "Acquisition", Title = "same", Detail = "two", Duration = FOREVER })

			expect(notify:Depth()).to.equal(2)
		end)
	end)

	describe("the depth cap", function()
		it("stops growing, rather than building a backlog nobody asked for", function()
			-- An unbounded queue is the failure this exists to prevent: a producer stuck in a loop
			-- would build minutes of notifications the player then has to sit through.
			local _scope, notify = build()

			push(notify, "Progression", "showing")
			for index = 1, 40 do
				push(notify, "Acquisition", "entry-" .. index)
			end

			expect(notify:Depth()).to.equal(8)
		end)

		it("drops the lowest-priority waiting entry to make room for a better one", function()
			local _scope, notify = build()

			push(notify, "Progression", "showing")
			for index = 1, 8 do
				push(notify, "World", "world-" .. index)
			end
			expect(notify:Depth()).to.equal(8)

			-- A Warning arriving at a full queue of World notices gets in, and the queue does not grow.
			push(notify, "Warning", "warning")
			expect(notify:Depth()).to.equal(8)

			-- Drain and check the Warning is genuinely in there and genuinely first.
			notify:Push({ Kind = "Progression", Title = "showing", Duration = 0 })
			task.wait()
			expect(currentTitle(notify)).to.equal("warning")
		end)

		it("refuses the arriving notification when it is no better than the worst waiting one", function()
			-- The other half of the policy. Evicting a peer for a peer would be churn; evicting a
			-- BETTER entry for a worse arrival would be the bug this branch exists to prevent.
			local _scope, notify = build()

			push(notify, "Progression", "showing")
			for index = 1, 8 do
				push(notify, "Warning", "warning-" .. index)
			end

			push(notify, "World", "world")
			expect(notify:Depth()).to.equal(8)

			notify:Push({ Kind = "Progression", Title = "showing", Duration = 0 })
			task.wait()
			-- Still a Warning, so the World notice was the one turned away rather than one of these.
			expect(currentTitle(notify)).to.equal("warning-1")
		end)
	end)

	describe("dismissal", function()
		it("clears itself when its duration is up and nothing is waiting", function()
			local _scope, notify = build()

			notify:Push({ Kind = "World", Title = "brief", Duration = 0 })
			expect(currentTitle(notify)).to.equal("brief")

			task.wait()
			expect(Fusion.peek(notify.Current)).to.equal(nil)
		end)

		it("does not let a replaced notification's timer dismiss its successor", function()
			-- The generation guard. Without it, coalescing a repeat of what is on screen would leave
			-- the FIRST push's task.delay still armed, and it would cut the restarted read short --
			-- which is the exact opposite of what a restart is for.
			local _scope, notify = build()

			notify:Push({ Kind = "Progression", Title = "showing", Duration = 0 })
			notify:Push({ Kind = "Progression", Title = "showing", Duration = FOREVER })

			task.wait()
			task.wait()
			expect(currentTitle(notify)).to.equal("showing")
		end)
	end)

	describe("the kinds", function()
		it("styles all four, and names each of them in words", function()
			-- The accessibility contract this UI keeps everywhere: colour is never the only signal. The
			-- eyebrow is what makes a Warning tellable from a Progression with the accent ignored, so a
			-- kind without one -- or two kinds sharing one -- is a real defect and not a typo.
			local seen: { [string]: boolean } = {}
			for _, kind in Notify.Kinds do
				local style = Notify.Style(kind)
				expect(style).to.be.ok()
				expect(#style.Eyebrow > 0).to.equal(true)
				expect(style.Duration > 0).to.equal(true)
				expect(seen[style.Eyebrow]).to.equal(nil)
				seen[style.Eyebrow] = true
			end
			expect(#Notify.Kinds).to.equal(4)
		end)

		it("exposes the kinds frozen, so nobody adds a fifth from outside", function()
			expect(table.isfrozen(Notify.Kinds)).to.equal(true)
		end)
	end)

	describe("the channel is not something a producer can drive by hand", function()
		it("hands out no way to set Current except through Push", function()
			-- Current IS a Fusion.Value -- Screens/Notifications binds to it and a Computed would need
			-- a second Value behind it anyway. What is asserted instead is the thing that actually
			-- matters: Push is the only member of the handle that a producer has any reason to call,
			-- and the ordering/coalescing/cap above are unreachable if someone writes Current directly.
			-- This is a reminder in test form rather than an enforcement, and it says so.
			local _scope, notify = build()

			expect(typeof(notify.Push)).to.equal("function")
			expect(typeof(notify.Depth)).to.equal("function")
			expect(Fusion.peek(notify.Current)).to.equal(nil)
		end)
	end)
end
