--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeNotifier = require(ReplicatedStorage.Shared.ChangeNotifier)

-- A bare Instance, not a plain Lua table, stands in for "player" here -- BindableEvent:Fire (the
-- mechanism Update uses to fire Changed) deep-copies plain table arguments same as a RemoteEvent
-- would, so a `{} :: any` fake player (the trick RateLimiter.spec.lua/BotCombat.spec.lua use for
-- specs that never cross a BindableEvent boundary) would arrive at a Changed connection as a
-- DIFFERENT table, breaking reference-equality assertions. A real Instance is never copied this way
-- (Roblox instances always pass by reference), which is also why a genuine Player always survives
-- the round trip correctly in production.
local function makeFakePlayer(): Player
	return (Instance.new("Folder") :: any) :: Player
end

return function()
	describe("ChangeNotifier", function()
		it("does not fire on the first Update for a player, regardless of the value", function()
			local notifier = ChangeNotifier.New()
			local player = makeFakePlayer()
			local fireCount = 0
			notifier.Changed.Event:Connect(function()
				fireCount += 1
			end)

			local fired = notifier:Update(player, true)

			expect(fired).to.equal(false)
			expect(fireCount).to.equal(0)
		end)

		it("fires Changed(player, newValue) only when the value actually transitions", function()
			local notifier = ChangeNotifier.New()
			local player = makeFakePlayer()
			local calls: { { Player: Player, Value: boolean } } = {}
			notifier.Changed.Event:Connect(function(firedPlayer: Player, value: boolean)
				table.insert(calls, { Player = firedPlayer, Value = value })
			end)

			notifier:Update(player, false) -- baseline, no fire
			expect(notifier:Update(player, false)).to.equal(false) -- unchanged, no fire
			expect(#calls).to.equal(0)

			expect(notifier:Update(player, true)).to.equal(true) -- transition, fires
			expect(#calls).to.equal(1)
			expect(calls[1].Player).to.equal(player)
			expect(calls[1].Value).to.equal(true)

			expect(notifier:Update(player, true)).to.equal(false) -- still true, no fire
			expect(#calls).to.equal(1)

			expect(notifier:Update(player, false)).to.equal(true) -- transitions back, fires
			expect(#calls).to.equal(2)
			expect(calls[2].Value).to.equal(false)
		end)

		it("tracks independent state per player", function()
			local notifier = ChangeNotifier.New()
			local playerA = makeFakePlayer()
			local playerB = makeFakePlayer()
			local calls: { Player } = {}
			notifier.Changed.Event:Connect(function(firedPlayer: Player)
				table.insert(calls, firedPlayer)
			end)

			notifier:Update(playerA, false)
			notifier:Update(playerB, false)

			notifier:Update(playerA, true)

			expect(#calls).to.equal(1)
			expect(calls[1]).to.equal(playerA)
			-- playerB's own baseline is untouched by playerA's transition.
			expect(notifier:Update(playerB, false)).to.equal(false)
		end)

		it("Clear drops a player's last-known value so their next Update is a fresh baseline", function()
			local notifier = ChangeNotifier.New()
			local player = makeFakePlayer()
			local fireCount = 0
			notifier.Changed.Event:Connect(function()
				fireCount += 1
			end)

			notifier:Update(player, true)
			notifier:Clear(player)

			-- Without the Clear, this would be a transition (true -> false) and fire; with it, this
			-- is treated as a fresh first observation instead, matching a rejoining/respawned player
			-- having no meaningful "last told" value to have transitioned away from.
			local fired = notifier:Update(player, false)

			expect(fired).to.equal(false)
			expect(fireCount).to.equal(0)
		end)

		it("keeps separate instances independent", function()
			local notifierA = ChangeNotifier.New()
			local notifierB = ChangeNotifier.New()
			local player = makeFakePlayer()

			notifierA:Update(player, false)
			notifierB:Update(player, false)

			expect(notifierA:Update(player, true)).to.equal(true)
			-- A transition recorded on notifierA must never leak into notifierB's own bookkeeping.
			expect(notifierB:Update(player, true)).to.equal(true)
		end)
	end)
end
