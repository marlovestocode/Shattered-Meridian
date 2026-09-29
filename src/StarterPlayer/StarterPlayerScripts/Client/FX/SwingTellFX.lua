--!strict
--[[
	SwingTellFX.lua

	Owns: drawing the heavy tell (AttackConstants.Tell) on OTHER combatants -- a red Highlight on anyone
	winding up a swing heavy enough that blocking it is the wrong answer, intensifying toward the strike
	and gone when the hit window opens.

	DRIVEN BY A TAG THE SERVER PUBLISHES. AttackRequestSystem tags the thrower's model with Tell.Tag and
	stamps Tell.UntilAttribute (server time) for the windup; it removes the tag at the windup's end, or
	early on a feint, a parry, or a hit that cuts the swing. This module only reacts: tag added -> build the
	Highlight and tween it toward the strike; tag removed -> tear it down. So any combatant can carry a tell
	-- players, training bots, dummies -- and nothing here needs to know which.

	NOT DRAWN ON THE LOCAL PLAYER. The thrower knows what they threw, and a red wash over your own body
	mid-swing is noise.

	The Highlight is created by this client and parented under the (replicated) model, so it is local to
	this client and is destroyed with the model if it despawns mid-tell.

	Does not own: which swings get a tell, or when it ends (the server), or anything about the swing itself.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("SwingTellFX")

local SwingTellFX = {}

local HIGHLIGHT_NAME = "SwingTell"

-- The live Highlight per tagged model.
local active: { [Instance]: Highlight } = {}
local started = false

local function clear(model: Instance): ()
	local highlight = active[model]
	active[model] = nil
	if highlight then
		highlight:Destroy()
	end
end

local function onTagged(model: Instance): ()
	if not model:IsA("Model") then
		return
	end
	local localCharacter = Players.LocalPlayer.Character
	if model == localCharacter then
		return
	end
	clear(model)

	local tell = AttackConstants.Tell
	local untilTime = model:GetAttribute(tell.UntilAttribute)
	local remaining = if typeof(untilTime) == "number" then untilTime - Workspace:GetServerTimeNow() else 0
	-- A tell whose windup has already run out on this client's clock (it arrived late) is not worth a
	-- flash: the strike has landed or is landing.
	if remaining <= 0.02 then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = HIGHLIGHT_NAME
	highlight.Adornee = model
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = tell.Color
	highlight.OutlineColor = tell.Color
	highlight.FillTransparency = tell.StartFillTransparency
	highlight.OutlineTransparency = tell.OutlineTransparency
	highlight.Parent = model
	active[model] = highlight

	TweenService:Create(highlight, TweenInfo.new(remaining, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		FillTransparency = tell.PeakFillTransparency,
	}):Play()
end

function SwingTellFX.Start(): ()
	if started then
		return
	end
	started = true
	if not AttackConstants.Tell.Enabled then
		return
	end
	local tag = AttackConstants.Tell.Tag
	CollectionService:GetInstanceAddedSignal(tag):Connect(onTagged)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(clear)
	for _, model in CollectionService:GetTagged(tag) do
		onTagged(model)
	end
	logger:debug("SwingTellFX started")
end

return SwingTellFX
