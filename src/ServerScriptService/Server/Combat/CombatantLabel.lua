--!strict
--[[
	CombatantLabel.lua

	Owns: the floating BillboardGui nameplate a bare NPC Humanoid needs to be visually distinguishable
	at a glance (unlike a real Player's character, it gets no automatic nameplate from Roblox's core
	UI). Shared by DummyCombat.lua and BotCombat.lua -- both used to hand-duplicate this exact
	attachment (text/color were the only per-kind difference) as a private helper inside
	CombatSystem.lua before those two moved out to their own modules; this is the one place either
	needs it now, and neither has to depend on the other (or on CombatSystem.lua) to get it.

	Does not own: any combat state -- purely a one-shot Instance-construction helper, no return
	value, nothing to update per-tick.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local CombatantLabel = {}

function CombatantLabel.Attach(model: Model, text: string, color: Color3): ()
	local adornee = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
	if not adornee or not adornee:IsA("BasePart") then
		return
	end

	local labelConfig = Constants.Debug.CombatantLabel

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CombatantLabel"
	billboard.Size = labelConfig.Size
	billboard.StudsOffset = labelConfig.StudsOffset
	billboard.AlwaysOnTop = true
	billboard.Adornee = adornee
	billboard.Parent = adornee

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = labelConfig.Font
	label.TextSize = labelConfig.TextSize
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = labelConfig.TextStrokeTransparency
	label.Parent = billboard
end

return CombatantLabel
