--!strict
--[[
	AirComboFX.lua

	Owns: how an air combo LOOKS and FEELS on this client (docs/design/air-combat-and-evade.md B4) -- the
	readability every spectator gets, and the weight the two participants get:
	  * READABILITY, on every client, for every combatant: the AirComboPhase Attribute AirComboSystem
	    publishes on both participants' Humanoids. Held -> a red light column under the victim and a wind
	    trail on the attacker; Parried -> a blue flash and a shockwave ring; Dropped -> a grey puff;
	    Recovering -> a white shimmer; Slammed -> a dust crater; Spiked -> an orange flash. Launched, in the
	    combo, parried out, dropped, recovered -- each readable at a glance, with no remote at all.
	  * WEIGHT, on the two participants' own clients: Combat_Feedback's optional AirCombo tag (Launch / Hit /
	    Finisher / Clash) adds a camera punch and a shake on top of the ordinary hit presentation every
	    Clean hit already gets (hit-stop, sparks, audio -- CombatFeedbackClient). The finisher hits hardest,
	    and the air parry gets its own clash: a white ring at the contact, a double ring for a perfect one.

	BUILT FROM PRIMITIVES -- parts, Highlights, a Trail -- so it works the day it ships rather than waiting on
	uploaded assets this repo will not guess the ids of. Every camera effect goes through CameraShake/FOVOffset,
	which the player's comfort settings already gate.

	Watches combatants through the Combatant CollectionService tag (HitboxEngine tags every registered
	combatant, and tags replicate), so the training bot reads exactly like a player.

	Does not own: whether anything happened (the server), the ordinary hit presentation
	(CombatFeedbackClient), or the follow (Client/Combat/AirComboClient.lua).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local CameraShake = require(script.Parent.CameraShake)
local FOVOffset = require(script.Parent.FOVOffset)

local PRESENTATION = AirComboConstants.Presentation
local COLORS = PRESENTATION.Colors
local FOV_SLOT = "AirCombo"

local logger = Logger.scope("AirComboFX")

local AirComboFX = {}

local started = false
local effectsFolder: Folder? = nil
-- Per watched combatant: its Attribute connection, and the held-phase visuals while they last.
type Watched = {
	Trove: Trove.TroveInstance,
	Held: Trove.TroveInstance?,
}
local watched: { [Model]: Watched } = {}

-- Helpers ------------------------------------------------------------------------------------------

local function folder(): Folder
	local existing = effectsFolder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "AirComboFX"
	created.Parent = Workspace
	effectsFolder = created
	return created
end

local function withinDrawDistance(position: Vector3): boolean
	local camera = Workspace.CurrentCamera
	return camera ~= nil and (camera.CFrame.Position - position).Magnitude <= PRESENTATION.MaxDrawDistanceStuds
end

local function effectPart(shape: Enum.PartType, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	return part
end

-- A flat ring expanding outward from `position` and fading out.
local function ring(position: Vector3, color: Color3, delaySeconds: number?): ()
	if not withinDrawDistance(position) then
		return
	end
	local function spawnRing()
		local part = effectPart(Enum.PartType.Cylinder, color, 0.2)
		local start = PRESENTATION.RingStartStuds
		part.Size = Vector3.new(0.15, start, start)
		-- A Cylinder's axis is X; roll it onto its side so the disc lies flat.
		part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
		part.Parent = folder()
		local finish = PRESENTATION.RingEndStuds
		local tween = TweenService:Create(
			part,
			TweenInfo.new(PRESENTATION.RingSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.05, finish, finish), Transparency = 1 }
		)
		tween:Play()
		task.delay(PRESENTATION.RingSeconds + 0.05, function()
			part:Destroy()
		end)
	end
	if delaySeconds and delaySeconds > 0 then
		task.delay(delaySeconds, spawnRing)
	else
		spawnRing()
	end
end

local function puff(position: Vector3, color: Color3): ()
	if not withinDrawDistance(position) then
		return
	end
	local part = effectPart(Enum.PartType.Ball, color, 0.35)
	part.Material = Enum.Material.SmoothPlastic
	part.Size = Vector3.one * 1.5
	part.CFrame = CFrame.new(position)
	part.Parent = folder()
	local size = PRESENTATION.PuffEndStuds
	TweenService:Create(part, TweenInfo.new(PRESENTATION.PuffSeconds, Enum.EasingStyle.Quad), {
		Size = Vector3.one * size,
		Transparency = 1,
	}):Play()
	task.delay(PRESENTATION.PuffSeconds + 0.05, function()
		part:Destroy()
	end)
end

-- A whole-body flash: a Highlight that fades out.
local function flash(character: Model, color: Color3): ()
	local root = CharacterUtil.RootOf(character)
	if not root or not withinDrawDistance(root.Position) then
		return
	end
	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = 0.35
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = character
	highlight.Parent = folder()
	TweenService:Create(highlight, TweenInfo.new(PRESENTATION.FlashSeconds), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()
	task.delay(PRESENTATION.FlashSeconds + 0.05, function()
		highlight:Destroy()
	end)
end

-- The held-phase visuals, alive for as long as the combatant is Rising/Held/Finishing.
local function heldVisuals(character: Model, humanoid: Humanoid): Trove.TroveInstance?
	local root = CharacterUtil.RootOf(character)
	if not root then
		return nil
	end
	local trove = Trove.New()
	local isVictim = humanoid:GetAttribute(AttributeConstants.AirHeldUntil) ~= nil
	if isVictim then
		-- The light column under the body, following it every frame.
		local column = trove:Add(effectPart(Enum.PartType.Block, COLORS.Held, PRESENTATION.ColumnTransparency))
		local width = PRESENTATION.ColumnWidthStuds
		column.Size = Vector3.new(width, PRESENTATION.ColumnHeightStuds, width)
		column.Parent = folder()
		trove:Connect(RunService.RenderStepped, function()
			if root.Parent then
				column.CFrame = CFrame.new(root.Position - Vector3.new(0, PRESENTATION.ColumnHeightStuds * 0.5 + 1, 0))
			end
		end)
		local highlight = trove:Add(Instance.new("Highlight"))
		highlight.FillTransparency = 1
		highlight.OutlineColor = COLORS.Held
		highlight.OutlineTransparency = 0.3
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Adornee = character
		highlight.Parent = folder()
	else
		-- The attacker's wind trail.
		local top = trove:Add(Instance.new("Attachment"))
		top.Position = Vector3.new(0, 1, 0)
		top.Parent = root
		local bottom = trove:Add(Instance.new("Attachment"))
		bottom.Position = Vector3.new(0, -1, 0)
		bottom.Parent = root
		local trail = trove:Add(Instance.new("Trail"))
		trail.Attachment0 = top
		trail.Attachment1 = bottom
		trail.Lifetime = 0.18
		trail.Color = ColorSequence.new(Color3.new(1, 1, 1))
		trail.Transparency = NumberSequence.new(0.6, 1)
		trail.LightEmission = 0.5
		trail.FaceCamera = true
		trail.Parent = root
	end
	return trove
end

local function onPhaseChanged(character: Model, humanoid: Humanoid, state: Watched): ()
	local phase = humanoid:GetAttribute(AttributeConstants.AirComboPhase)
	local live = phase == "Rising" or phase == "Held" or phase == "Finishing"
	if live and state.Held == nil then
		state.Held = heldVisuals(character, humanoid)
	elseif not live and state.Held then
		(state.Held :: Trove.TroveInstance):Clean()
		state.Held = nil
	end

	local root = CharacterUtil.RootOf(character)
	if not root then
		return
	end
	local position = root.Position
	if phase == "Parried" then
		flash(character, COLORS.Parried)
		ring(position, COLORS.Parried)
	elseif phase == "Dropped" then
		puff(position, COLORS.Dropped)
	elseif phase == "Recovering" then
		flash(character, COLORS.Recovering)
	elseif phase == "Slammed" then
		-- The crater is drawn where the body lands, a moment after the phase publishes.
		task.delay(0.12, function()
			if root.Parent then
				ring(root.Position - Vector3.new(0, 2.5, 0), COLORS.Slammed)
				puff(root.Position - Vector3.new(0, 2.5, 0), COLORS.Slammed)
			end
		end)
	elseif phase == "Spiked" then
		flash(character, COLORS.Spiked)
	end
end

local function watch(instance: Instance): ()
	if not instance:IsA("Model") or watched[instance] then
		return
	end
	local character = instance :: Model
	local humanoid = CharacterUtil.HumanoidOf(character)
	if not humanoid then
		return
	end
	local state: Watched = { Trove = Trove.New(), Held = nil }
	watched[character] = state
	local boundHumanoid = humanoid :: Humanoid
	state.Trove:Connect(boundHumanoid:GetAttributeChangedSignal(AttributeConstants.AirComboPhase), function()
		onPhaseChanged(character, boundHumanoid, state)
	end)
	-- A combatant that streamed in mid-combo reads correctly from its first frame.
	onPhaseChanged(character, boundHumanoid, state)
end

local function unwatch(instance: Instance): ()
	local state = watched[instance :: any]
	if not state then
		return
	end
	watched[instance :: any] = nil
	if state.Held then
		state.Held:Clean()
	end
	state.Trove:Clean()
end

-- Public -------------------------------------------------------------------------------------------

-- The participants' weight, from Combat_Feedback's AirCombo tag. Called by CombatFeedbackClient for every
-- feedback payload that carries one -- on the attacker's and the victim's own clients only, because that is
-- who Combat_Feedback is sent to.
function AirComboFX.OnFeedback(payload: DamageTypes.CombatFeedback): ()
	local tag = payload.AirCombo
	if tag == nil then
		return
	end
	local punch = (PRESENTATION.Punch :: any)[tag]
	if punch then
		FOVOffset.Punch(FOV_SLOT, punch.Delta, punch.OutSeconds, punch.BackSeconds)
	end
	local shake = (PRESENTATION.Shake :: any)[tag]
	if shake then
		CameraShake.Shake(shake)
	end
	if tag == "Clash" then
		ring(payload.ContactPosition, COLORS.Clash)
		if payload.Perfect == true then
			ring(payload.ContactPosition, COLORS.Parried, 0.08)
		end
	end
end

function AirComboFX.Start(): ()
	if started then
		return
	end
	started = true
	local tag = HitboxEngineConstants.CombatantTag
	for _, instance in CollectionService:GetTagged(tag) do
		watch(instance)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(watch)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(unwatch)
	logger:debug("AirComboFX started")
end

return AirComboFX
