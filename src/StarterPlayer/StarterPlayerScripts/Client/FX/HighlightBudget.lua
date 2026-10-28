--!strict
--[[
	HighlightBudget.lua

	Owns: every client Highlight's share of the engine's render budget. `HighlightBudget.Acquire(owner)` hands back a fresh
	Highlight while fewer than FXConstants.HighlightBudget.MaxLive are alive, or nil when the budget is spent; the caller skips
	that effect. A Highlight counts until it is destroyed (its own Destroying signal returns the slot), so every existing way an
	effect ends -- a fade's task.delay, a Trove, the adorned model being removed with the Highlight parented under it -- returns
	it without a second call.

	WHY (coworking plan W19). Roblox renders at most 31 Highlights at once and silently skips the rest -- no error, just an outline
	that never appears. HitFlash, SwingTellFX and AirComboFX each kept their own cap (6, its own count, none), and in a crowded
	fight their sum passed the engine's: whichever effect was created last simply did not show, and which one that was depended on
	timing. One budget, below the engine's limit, means a refused effect is the one that ASKED last, on purpose, and the count is
	visible (`Live`).

	Does not own: what a Highlight looks like, where it is parented, or when an effect ends -- each caller keeps that. Server-side
	debug Highlights (HitboxEngine's) are not on this client's budget.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("HighlightBudget")

local HighlightBudget = {}

local live = 0
-- Owner -> when it was last told no, so a crowd logs one line a second per owner, not one per refused flash.
local lastRefusalLogAt: { [string]: number } = {}

function HighlightBudget.Acquire(owner: string): Highlight?
	if live >= FXConstants.HighlightBudget.MaxLive then
		local now = os.clock()
		if now - (lastRefusalLogAt[owner] or -math.huge) >= 1 then
			lastRefusalLogAt[owner] = now
			logger:debug("Highlight refused -- budget spent", { owner = owner, live = live })
		end
		return nil
	end
	local highlight = Instance.new("Highlight")
	live += 1
	local returned = false
	highlight.Destroying:Once(function()
		if not returned then
			returned = true
			live -= 1
		end
	end)
	return highlight
end

-- Highlights alive right now that came from this budget.
function HighlightBudget.Live(): number
	return live
end

return HighlightBudget
